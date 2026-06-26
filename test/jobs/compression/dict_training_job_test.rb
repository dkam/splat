require "test_helper"

class Compression::DictTrainingJobTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Test Project", slug: "test", public_key: "test-key")
  end

  # Build n events whose decoded payloads share enough structure for zstd to
  # learn a dictionary. `value_bytes` pads each payload so we can drive the
  # byte-budget / truncation paths without needing production-sized data.
  def seed_events(n, value_bytes: 200)
    n.times do |i|
      payload = {
        "message" => "boom #{i}",
        "platform" => "ruby",
        "timestamp" => Time.current.iso8601,
        "exception" => {"values" => [{"type" => "RuntimeError", "value" => "x" * value_bytes,
                                      "stacktrace" => {"frames" => Array.new(15) { |j| {"filename" => "app/models/thing_#{j}.rb", "lineno" => j, "function" => "call"} }}}]}
      }
      Event.create_from_sentry_payload!("evt-#{i}", payload, @project)
    end
  end

  def last_run
    Compression::IssuesEventsDict.connection.exec_query(
      "SELECT * FROM dictionary_training_runs ORDER BY id DESC LIMIT 1"
    ).first
  end

  def with_const(klass, name, value)
    old = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, old)
  end

  test "trains and promotes a first dictionary for events" do
    seed_events(150)

    assert_difference -> { Compression::IssuesEventsDict.where(segment: "events", active: true).count }, 1 do
      Compression::DictTrainingJob.new.perform("events")
    end

    run = last_run
    assert_equal 1, run["promoted"]
    assert_operator run["samples"], :>=, 100
    assert_operator run["candidate_ratio"].to_f, :>, 0.0
  end

  test "skips and logs when there are too few samples" do
    seed_events(20)

    assert_no_difference -> { Compression::IssuesEventsDict.count } do
      Compression::DictTrainingJob.new.perform("events")
    end

    assert_match(/too few samples/, last_run["notes"])
  end

  test "bounds the training set by bytes rather than holding the whole corpus" do
    # Each payload decodes to >40 KB; with a tiny byte budget the job must stop
    # well before consuming all rows, proving it streams + caps instead of
    # materialising everything (the OOM that took down the ingest worker).
    seed_events(120, value_bytes: 40_000)

    cap = 200_000 # 200 KB training budget
    with_const(Compression::DictTrainingJob, :TRAIN_MAX_BYTES, cap) do
      Compression::DictTrainingJob.new.perform("events")
    end

    # 200 KB budget / ~40 KB-per-train-sample ⇒ only a handful of train samples,
    # so the logged sample count stays far below the 120 rows available.
    assert_operator last_run["samples"], :<, 60
  end
end

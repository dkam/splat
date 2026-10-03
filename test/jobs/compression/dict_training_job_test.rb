require "test_helper"

class Compression::DictTrainingJobTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Test Project", slug: "test", public_key: "test-key")
  end

  # Build n events whose decoded payloads share enough structure for zstd to
  # learn a dictionary. `value_bytes` pads each payload so we can drive the
  # byte-budget / truncation paths without needing production-sized data.
  # `type` picks the issue (events group by exception type + top frame), and
  # `at` the event timestamp.
  def seed_events(n, value_bytes: 200, type: "RuntimeError", at: Time.current)
    n.times do |i|
      payload = {
        "message" => "boom #{i}",
        "platform" => "ruby",
        "timestamp" => at.iso8601,
        "exception" => {"values" => [{"type" => type, "value" => "x" * value_bytes,
                                      "stacktrace" => {"frames" => Array.new(15) { |j| {"filename" => "app/models/thing_#{j}.rb", "lineno" => j, "function" => "call"} }}}]}
      }
      Event.create_from_sentry_payload!("evt-#{SecureRandom.hex(8)}", payload, @project)
    end
  end

  # Run only the sampler (no zstd) and tally the exception type of every
  # sampled payload, train and eval together.
  def sampled_types
    Dir.mktmpdir do |dir|
      train_dir = File.join(dir, "train")
      eval_dir = File.join(dir, "eval")
      Dir.mkdir(train_dir)
      Dir.mkdir(eval_dir)
      Compression::DictTrainingJob.new.send(:stream_samples, db: :issues_events, table: "events",
        segment: "events", train_dir: train_dir, eval_dir: eval_dir)
      Dir[File.join(dir, "*", "*")].map { |f| JSON.parse(File.read(f)).dig("exception", "values", 0, "type") }.tally
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

    result = nil
    assert_difference -> { Compression::IssuesEventsDict.where(segment: "events", active: true).count }, 1 do
      result = Compression::DictTrainingJob.new.perform("events")
    end

    run = last_run
    assert_equal 1, run["promoted"]
    assert_operator run["samples"], :>=, 100
    assert_operator run["candidate_ratio"].to_f, :>, 0.0

    # perform returns a usable score summary (not a raw ActiveRecord::Result).
    assert_operator result[:promoted_version], :>=, 1
    assert_operator result[:candidate_ratio], :>, 0.0
    assert_operator result[:candidate_ratio], :<, 1.0
    assert_equal run["samples"], result[:samples]   # samples == training-set size
    assert_operator result[:eval_samples], :>, 0
  end

  test "skips and logs when there are too few samples" do
    seed_events(20)

    assert_no_difference -> { Compression::IssuesEventsDict.count } do
      Compression::DictTrainingJob.new.perform("events")
    end

    assert_match(/too few samples/, last_run["notes"])
  end

  test "bounds the training set by bytes rather than holding the whole corpus" do
    # Each payload decodes to >40 KB; with a tiny byte budget the training set
    # must stop well before consuming all rows, proving it streams + caps the
    # *training* corpus instead of materialising everything (the OOM that took
    # down the ingest worker). 200 KB / ~40 KB-per-sample ⇒ a handful of train
    # samples, so the logged (training) sample count stays far below 120.
    seed_events(120, value_bytes: 40_000)

    with_const(Compression::DictTrainingJob, :TRAIN_MAX_BYTES, 200_000) do
      Compression::DictTrainingJob.new.perform("events")
    end

    assert_operator last_run["samples"], :<, 60
  end

  test "eval set is decoupled from the training cap and grows to EVAL_TARGET" do
    # The wobble fix: the training set is memory-bounded (small), but eval keeps
    # filling past where training stopped — up to EVAL_TARGET — so the score is
    # measured on many more samples. stream_samples is exercised directly (no
    # zstd) to assert the split sizes precisely. Spread over several issues so
    # ISSUE_DAY_CAP doesn't thin the pool below EVAL_TARGET.
    7.times { |k| seed_events(50, type: "Spread#{k}Error") }
    job = Compression::DictTrainingJob.new

    Dir.mktmpdir do |dir|
      train_dir = File.join(dir, "train")
      eval_dir = File.join(dir, "eval")
      Dir.mkdir(train_dir)
      Dir.mkdir(eval_dir)

      counts =
        with_const(Compression::DictTrainingJob, :TRAIN_MAX_BYTES, 60_000) do
          with_const(Compression::DictTrainingJob, :EVAL_TARGET, 200) do
            job.send(:stream_samples, db: :issues_events, table: "events", segment: "events",
              train_dir: train_dir, eval_dir: eval_dir)
          end
        end

      assert_operator counts[:eval], :>=, 200            # eval reached its own target...
      assert_operator counts[:eval], :>, counts[:train]  # ...past where training stopped
      assert_operator counts[:train], :>=, 1
      assert_equal counts[:train], Dir.children(train_dir).size
      assert_equal counts[:eval], Dir.children(eval_dir).size
    end
  end

  test "an issue that floods the window is capped in the sample" do
    # A bug firing thousands of times in an afternoon must not become the whole
    # training and eval set — the dict it produces is tuned for traffic that has
    # usually stopped by the time the nightly run promotes it.
    seed_events(60, type: "FloodError")
    5.times { |k| seed_events(10, type: "Steady#{k}Error") }

    types = with_const(Compression::DictTrainingJob, :ISSUE_DAY_CAP, 20) { sampled_types }

    assert_equal 20, types["FloodError"]
    5.times { |k| assert_equal 10, types["Steady#{k}Error"] }  # under the cap: all kept
  end

  test "the issue cap is per day, so an issue loud every day keeps its weight" do
    3.times { |d| seed_events(30, type: "DailyError", at: d.days.ago) }

    types = with_const(Compression::DictTrainingJob, :ISSUE_DAY_CAP, 20) { sampled_types }

    assert_equal 60, types["DailyError"]
  end
end

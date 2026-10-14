# frozen_string_literal: true

require "test_helper"

class Ingest::SpoolTest < ActiveSupport::TestCase
  test "queues a job straight to tuber when tuber is up" do
    puts = capture_tuber_puts { assert_equal :queued, Ingest::Spool.put("splat.events", {"a" => 1}) }

    assert_equal [["splat.events", {"a" => 1}]], puts
    assert_equal 0, Ingest::Spool.stats[:jobs]
  end

  test "keeps the job on disk when tuber can't be reached" do
    result = with_tuber_down { Ingest::Spool.put("splat.events", {"a" => 1}) }

    assert_equal :spooled, result
    assert_equal 1, Ingest::Spool.stats[:jobs]
    assert_operator Ingest::Spool.stats[:bytes], :>, 0
  end

  test "is full once the spool reaches its cap" do
    Ingest::Spool.max_bytes = 100
    with_tuber_down do
      Ingest::Spool.put("splat.events", {"a" => "x" * 40})
      assert_raises(Ingest::Spool::Full) { Ingest::Spool.put("splat.events", {"a" => "x" * 40}) }
    end

    assert_equal 1, Ingest::Spool.stats[:jobs]
  end

  test "is full from the start with a cap of 0, which turns spooling off" do
    Ingest::Spool.max_bytes = 0

    with_tuber_down do
      assert_raises(Ingest::Spool::Full) { Ingest::Spool.put("splat.events", {"a" => 1}) }
    end
  end

  test "is full when the disk refuses the write" do
    file = Tempfile.new("not-a-directory")
    Ingest::Spool.dir = file.path

    with_tuber_down do
      assert_raises(Ingest::Spool::Full) { Ingest::Spool.put("splat.events", {"a" => 1}) }
    end
  ensure
    file&.close!
  end

  test "replays spooled jobs oldest first, and removes each once tuber has it" do
    with_tuber_down do
      Ingest::Spool.put("splat.events", {"n" => 1})
      Ingest::Spool.put("splat.logs", {"n" => 2})
    end

    replayed = nil
    puts = capture_tuber_puts { replayed = Ingest::Spool.replay }

    assert_equal 2, replayed
    assert_equal [["splat.events", {"n" => 1}], ["splat.logs", {"n" => 2}]], puts
    assert_equal 0, Ingest::Spool.stats[:jobs]
  end

  test "stops replaying when tuber goes away again, and keeps what's left" do
    with_tuber_down do
      3.times { Ingest::Spool.put("splat.events", {"n" => it}) }
    end

    taken = 0
    put = ->(*, **) { raise Errno::ECONNREFUSED if (taken += 1) > 1 }
    replayed = with_stub(Ingest::Tuber, :put, put) { Ingest::Spool.replay }

    assert_equal 1, replayed
    assert_equal 2, Ingest::Spool.stats[:jobs]
  end

  # Tuber would refuse it every time; kept, it would stop the replay for good.
  test "drops a spooled job tuber refuses as too big, and carries on" do
    with_tuber_down do
      Ingest::Spool.put("splat.events", {"n" => "big"})
      Ingest::Spool.put("splat.events", {"n" => "small"})
    end

    queued = []
    put = ->(tube, payload, **) { (payload["n"] == "big") ? raise(::Tuber::JobTooBigError.new("JOB_TOO_BIG", "put")) : queued << payload }
    with_stub(Ingest::Tuber, :put, put) { Ingest::Spool.replay }

    assert_equal [{"n" => "small"}], queued
    assert_equal 0, Ingest::Spool.stats[:jobs]
  end

  test "the replayer replays the spool until stopped" do
    with_tuber_down { Ingest::Spool.put("splat.events", {"n" => 1}) }
    replayer = Ingest::SpoolReplayer.new(interval: 0.01)

    puts = capture_tuber_puts do
      thread = Thread.new { replayer.run }
      sleep 0.01 until Ingest::Spool.stats[:jobs].zero?
      replayer.stop!
      assert thread.join(2), "the replayer didn't stop"
    end

    assert_equal [["splat.events", {"n" => 1}]], puts
  end

  private

  def with_tuber_down(&)
    with_stub(Ingest::Tuber, :put, ->(*, **) { raise Errno::ECONNREFUSED }, &)
  end

  def capture_tuber_puts
    calls = []
    with_stub(Ingest::Tuber, :put, ->(tube, payload, **) { calls << [tube, payload] }) { yield }
    calls
  end
end

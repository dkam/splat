# frozen_string_literal: true

require "test_helper"

class Ingest::TubeConsumerTest < ActiveSupport::TestCase
  # Beaneater-shaped fake: client.tubes.watch!(name) + client.close.
  class FakeClient
    attr_reader :watched, :closed

    def initialize
      @watched = []
      @closed = false
    end

    def tubes = self
    def watch!(name) = @watched << name
    def close = (@closed = true)
  end

  # A concrete consumer that records waits instead of really sleeping, so the
  # retry loop runs instantly.
  class TestConsumer < Ingest::TubeConsumer
    attr_reader :waits

    def initialize
      super(tube: "splat.test")
      @waits = 0
    end

    def process_batch(jobs) = nil

    private

    def interruptible_sleep(_seconds) = (@waits += 1)
  end

  # Counts touches instead of talking to tuber. #touch on a job that's been
  # deleted (or whose reservation lapsed) raises, exactly as beaneater's
  # with_reserved does — the heartbeat must shrug that off.
  class FakeJob
    attr_reader :touches

    def initialize(dead: false)
      @touches = 0
      @dead = dead
    end

    def touch
      raise Beaneater::JobNotReserved, "not reserved" if @dead
      @touches += 1
    end
  end

  # Heartbeats on a millisecond interval so a "slow" batch is milliseconds
  # rather than minutes. Overrides the method, not the constant — Ruby resolves
  # TOUCH_INTERVAL lexically, so redefining it here would change nothing.
  class FastTouchConsumer < Ingest::TubeConsumer
    def initialize(&block)
      super(tube: "splat.test")
      @block = block
    end

    def process_batch(jobs) = @block.call(jobs)

    private

    def touch_interval = 0.005
  end

  test "a batch slower than its TTR keeps its reservations alive" do
    # The bug this exists to prevent: StorageStatsJob ran ~40 minutes against a
    # 120s TTR, so tuber handed its job to someone else mid-run and the worker
    # re-ran it forever, starving the tube retention lives on.
    job = FakeJob.new
    consumer = FastTouchConsumer.new { sleep 0.05 }

    consumer.send(:keeping_alive, [job]) { sleep 0.05 }

    assert_operator job.touches, :>, 0, "a slow batch must touch its jobs to hold the reservation"
  end

  test "process_one_batch keeps a slow batch's jobs alive" do
    # Covers the wiring, not just keeping_alive in isolation: drop the wrapper
    # from process_one_batch and this is the test that notices.
    job = FakeJob.new
    consumer = FastTouchConsumer.new { sleep 0.05 }
    consumer.define_singleton_method(:reserve_batch) { [job] }

    consumer.send(:process_one_batch)

    assert_operator job.touches, :>, 0, "the real batch path must hold its reservations"
  end

  test "the heartbeat stops once the batch is done" do
    job = FakeJob.new
    consumer = FastTouchConsumer.new { nil }

    consumer.send(:keeping_alive, [job]) { nil }
    settled = job.touches
    sleep 0.05

    assert_equal settled, job.touches, "heartbeat must not outlive the batch"
  end

  test "the heartbeat survives a job that can no longer be touched" do
    # Jobs get deleted as a batch progresses; touching them then is expected.
    dead = FakeJob.new(dead: true)
    live = FakeJob.new

    assert_nothing_raised do
      FastTouchConsumer.new { nil }.send(:keeping_alive, [dead, live]) { sleep 0.05 }
    end
    assert_operator live.touches, :>, 0, "one dead job must not stop the others being kept alive"
  end

  test "keeping_alive stops the heartbeat even when the batch raises" do
    job = FakeJob.new
    consumer = FastTouchConsumer.new { nil }

    assert_raises(RuntimeError) do
      consumer.send(:keeping_alive, [job]) { raise "boom" }
    end
    settled = job.touches
    sleep 0.05

    assert_equal settled, job.touches, "a raising batch must still stop its heartbeat"
  end

  test "connect_with_retry waits for tuber to come up, then watches the tube" do
    attempts = 0
    client = FakeClient.new
    stub = -> {
      attempts += 1
      raise Beaneater::NotConnected, "connection refused" if attempts < 3
      client
    }

    consumer = TestConsumer.new
    ok = with_stub(Ingest::Tuber, :consumer_client, stub) do
      consumer.send(:connect_with_retry)
    end

    assert ok, "should report success once connected"
    assert_equal ["splat.test"], client.watched, "should watch its own tube"
    assert_equal 3, attempts, "should keep retrying until tuber answers"
    assert_equal 2, consumer.waits, "should back off between the two failures"
  end

  test "connect_with_retry aborts promptly when asked to stop" do
    consumer = TestConsumer.new
    consumer.stop!

    called = false
    ok = with_stub(Ingest::Tuber, :consumer_client, -> {
      called = true
      FakeClient.new
    }) do
      consumer.send(:connect_with_retry)
    end

    refute ok, "should report it never connected"
    refute called, "should not even attempt a connection once stopping"
  end

  test "reconnect closes the dead client and re-watches on a fresh one" do
    dead = FakeClient.new
    fresh = FakeClient.new
    consumer = TestConsumer.new
    consumer.instance_variable_set(:@client, dead)

    ok = with_stub(Ingest::Tuber, :consumer_client, -> { fresh }) do
      consumer.send(:reconnect)
    end

    assert ok
    assert dead.closed, "should close the dead connection"
    assert_equal ["splat.test"], fresh.watched, "should re-watch on the new connection"
  end
end

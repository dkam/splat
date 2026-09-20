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

  # Beaneater-shaped job for the finalize path: stats.releases drives the
  # release-vs-bury decision, and body/id are what a bury report has to carry.
  class FakeFinalizeJob
    Stats = Struct.new(:releases)
    attr_reader :id, :body, :buried, :released_with

    def initialize(releases:, body: "{}", id: 42)
      @releases = releases
      @body = body
      @id = id
      @buried = false
    end

    def stats = Stats.new(@releases)

    def bury = (@buried = true)

    def release(delay:) = (@released_with = delay)
  end

  def capture_bury_report(job)
    reported = nil
    with_stub(Sentry, :capture_message, ->(message, **opts) { reported = [message, opts] }) do
      TestConsumer.new.send(:bury_or_release, job)
    end
    reported
  end

  test "a job under the retry budget is released, not buried" do
    job = FakeFinalizeJob.new(releases: 2)

    assert_nil capture_bury_report(job), "a release is routine — don't alert on it"
    refute job.buried
    assert_equal Ingest::TubeConsumer::RETRY_DELAY, job.released_with
  end

  # A bury is silent data loss: the sender already got its 200, nothing
  # redelivers, and on splat.maintenance the buried job keeps holding its
  # idempotency key so the next run is suppressed too. It has to reach Sentry,
  # and it has to name the body well enough to go and find it.
  test "a job out of retries is buried and reported with something to find it by" do
    job = FakeFinalizeJob.new(
      releases: Ingest::TubeConsumer::MAX_RETRIES,
      body: {project_id: 1, transaction_id: "abc123", payload: {"huge" => "x" * 500}}.to_json
    )

    message, opts = capture_bury_report(job)

    assert job.buried, "out of retries means bury"
    assert_nil job.released_with
    assert_match "splat.test", message
    assert_equal ["ingest", "job_buried", "splat.test"], opts[:fingerprint]
    assert_equal 1, opts[:extra][:project_id]
    assert_equal "abc123", opts[:extra][:transaction_id]
    assert_equal 42, opts[:extra][:job_id]
    refute opts[:extra].key?(:payload), "ids only — the payload is the thing too big to log"
  end

  test "an unparsable body is reported as such rather than losing the report" do
    job = FakeFinalizeJob.new(releases: Ingest::TubeConsumer::MAX_RETRIES, body: "not json")

    _message, opts = capture_bury_report(job)

    assert job.buried
    assert_equal "unparsable", opts[:extra][:body]
  end

  test "a failing report never costs us the bury" do
    job = FakeFinalizeJob.new(releases: Ingest::TubeConsumer::MAX_RETRIES)

    with_stub(Sentry, :capture_message, ->(*, **) { raise "sentry is down" }) do
      assert_nothing_raised { TestConsumer.new.send(:bury_or_release, job) }
    end

    assert job.buried
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

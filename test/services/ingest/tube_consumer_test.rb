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

# frozen_string_literal: true

require "test_helper"

class Ingest::TuberTest < ActiveSupport::TestCase
  Stats = Struct.new(:current_jobs_ready, :current_jobs_reserved, :current_jobs_buried, :current_jobs_delayed)
  FakeTube = Struct.new(:stats)

  test "queue_depths reports per-tube ready/reserved/buried/delayed for every tube" do
    # Beaneater-shaped fake: producer.tubes[name].stats.current_jobs_*
    tubes = Hash.new do |_h, name|
      ready = (name == Ingest::Tuber::EVENTS_TUBE) ? 5 : 0
      FakeTube.new(Stats.new(ready, 1, 0, 0))
    end
    fake_producer = Struct.new(:tubes).new(tubes)

    depths = with_stub(Ingest::Tuber, :producer, -> { fake_producer }) do
      Ingest::Tuber.queue_depths
    end

    assert_equal Ingest::Tuber::ALL_TUBES.size, depths.size
    assert_equal({ready: 5, reserved: 1, buried: 0, delayed: 0}, depths[Ingest::Tuber::EVENTS_TUBE])
    assert_equal 0, depths[Ingest::Tuber::TRANSACTIONS_TUBE][:ready]
    assert depths.key?(Ingest::Tuber::MAINTENANCE_TUBE)
  end

  test "queue_depths degrades to {} when tuber is unreachable" do
    depths = with_stub(Ingest::Tuber, :producer, -> { raise "connection refused" }) do
      Ingest::Tuber.queue_depths
    end

    assert_equal({}, depths)
  end

  test "with_producer rebuilds the connection once after tuber drops, then succeeds" do
    calls = 0
    fresh = Object.new
    producer = -> {
      calls += 1
      raise Beaneater::NotConnected, "socket closed" if calls == 1
      fresh
    }

    result = with_stub(Ingest::Tuber, :producer, producer) do
      with_stub(Ingest::Tuber, :reset_producer!, -> {}) do
        Ingest::Tuber.with_producer { |conn| conn }
      end
    end

    assert_equal fresh, result, "should yield the rebuilt connection"
    assert_equal 2, calls, "should retry exactly once on a dead socket"
  end

  test "with_producer gives up (raises) if the rebuilt connection is also dead" do
    resets = 0
    assert_raises(Beaneater::NotConnected) do
      with_stub(Ingest::Tuber, :producer, -> { raise Beaneater::NotConnected, "still down" }) do
        with_stub(Ingest::Tuber, :reset_producer!, -> { resets += 1 }) do
          Ingest::Tuber.with_producer { |conn| conn }
        end
      end
    end

    assert_equal 2, resets, "should reset on the initial failure and the retry, then stop"
  end
end

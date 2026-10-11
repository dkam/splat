require "test_helper"

class Ingest::ScheduleTest < ActiveSupport::TestCase
  # Stands in for a Tuber client: runs the sync block against the gem's real
  # Builder, so the wire lines are the ones tuber would get, and keeps them.
  class FakeClient
    attr_reader :owner, :entries

    def initialize(&on_sync)
      @on_sync = on_sync
    end

    def schedules = self

    def sync(owner)
      @owner = owner
      builder = ::Tuber::Schedules::Builder.new
      yield builder
      @entries = builder.entries
      @on_sync ? @on_sync.call : ::Tuber::Schedules::SyncResult.new(builder.entries.size, 0, 0, 0)
    end

    def close = nil
  end

  def entry(name) = Ingest::Schedule.entry(name) || flunk("no #{name} in config/schedule.yml")

  test "an entry keeps its zone in the cron line" do
    assert_equal "0 2 * * * Australia/Melbourne", entry("data_retention").cron
    assert_equal "Australia/Melbourne", entry("data_retention").fugit.zone
    assert_equal "* * * * *", entry("monitor_evaluation").cron
  end

  test "each run's body names its entry, so the worker can record the run" do
    assert_equal({class: "Maintenance::StorageStatsJob", args: ["deep"], schedule: "storage_stats_deep"},
      entry("storage_stats_deep").body)
  end

  test "the idp key outlives the job by the cooldown" do
    assert_equal({con: 1, idp: ["data_retention", Ingest::Schedule::IDP_COOLDOWN]}, entry("data_retention").put_options)
    assert_equal({idp: ["monitor_evaluation", Ingest::Schedule::IDP_COOLDOWN]}, entry("monitor_evaluation").put_options)
  end

  test "a schedule that isn't a cron line is refused" do
    error = assert_raises(ArgumentError) do
      Ingest::Schedule.load({"x" => {"class" => "X", "tube" => "t", "schedule" => "every 10m"}})
    end
    assert_match "must be a cron line", error.message
  end

  test "a cron line fugit can't read is refused when the file loads, not when it fires" do
    assert_raises(ArgumentError) do
      Ingest::Schedule.load({"x" => {"class" => "X", "tube" => "t", "schedule" => "cron 0 2 * *"}})
    end
  end

  test "sync hands tuber every entry, as the same put bin/scheduler makes" do
    client = FakeClient.new
    Ingest::Schedule.sync(client)

    assert_equal "splat", client.owner
    assert_equal Ingest::Schedule.entries.map(&:name), client.entries.map(&:name)

    retention = client.entries.find { |e| e.name == "data_retention" }
    body = JSON.generate(entry("data_retention").body)
    assert_equal "data_retention splat.maintenance 1024 0 120 #{body.bytesize} " \
      "idp:data_retention:30 con:1 0 2 * * * Australia/Melbourne", retention.line
    assert_equal body, retention.body
  end

  test "a tuber without schedules is Unsupported, so bin/scheduler knows to fire them" do
    client = FakeClient.new { raise ::Tuber::ScheduleSyncError.new("UNKNOWN_COMMAND", "schedule-begin splat", owner: "splat") }

    assert_raises(Ingest::Schedule::Unsupported) { Ingest::Schedule.sync(client) }
  end

  test "a set tuber refuses is raised as tuber's error" do
    client = FakeClient.new { raise ::Tuber::ScheduleSyncError.new("BAD_SCHEDULE", "schedule-put x", owner: "splat", entry: "x") }

    error = assert_raises(::Tuber::ScheduleSyncError) { Ingest::Schedule.sync(client) }
    assert_equal "BAD_SCHEDULE", error.status
  end

  # --- Putting a lost schedule back ------------------------------------------

  # A producer whose tuber holds +held+ for Splat, or raises it.
  def producer_holding(held)
    schedules = Object.new
    schedules.define_singleton_method(:list) { |_owner| held.is_a?(Exception) ? raise(held) : held }
    conn = Object.new
    conn.define_singleton_method(:schedules) { schedules }
    conn
  end

  def restore(held)
    syncs = 0
    conn = producer_holding(held)
    result = with_stub(Ingest::Tuber, :with_producer, ->(&blk) { blk.call(conn) }) do
      with_stub(Ingest::Schedule, :sync, -> { syncs += 1 and ::Tuber::Schedules::SyncResult.new(9, 0, 0, 0) }) do
        Ingest::Schedule.restore_if_lost
      end
    end
    [result, syncs]
  end

  test "a tuber holding none of the schedule gets it back" do
    result, syncs = restore([])

    assert_equal 1, syncs
    assert_equal 9, result.added
  end

  test "a set tuber already holds is left alone: it may be a newer release's" do
    result, syncs = restore([["splat", "data_retention"]])

    assert_equal 0, syncs
    assert_nil result
  end

  test "a tuber too old to hold one is Unsupported" do
    assert_raises(Ingest::Schedule::Unsupported) { restore(::Tuber::UnknownCommandError.new("UNKNOWN_COMMAND", "schedule-list splat")) }
  end
end

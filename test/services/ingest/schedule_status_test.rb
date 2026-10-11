require "test_helper"

class Ingest::ScheduleStatusTest < ActiveSupport::TestCase
  Stats = Struct.new(:next_fire, :buried_streak)

  # 10:30:20 UTC on a Wednesday: monitor_evaluation (every minute) was due at
  # 10:30 and 10:29; histogram_rollup (:05 past) at 10:05 and 09:05.
  NOW = Time.utc(2026, 10, 14, 10, 30, 20)
  BOOTED = NOW - 1.hour

  def rows(held:, fallback: false)
    with_stub(Ingest::ScheduleStatus, :tuber_entries, -> { held }) do
      with_stub(Ingest::ScheduleStatus, :fallback_running?, -> { fallback }) do
        with_stub(Ingest::ScheduleStatus, :booted_at, -> { BOOTED }) do
          Ingest::ScheduleStatus.entries(now: NOW).to_h { |row| [row.entry.name, row] }
        end
      end
    end
  end

  def all_held(next_fire: NOW + 1.minute, buried_streak: 0)
    Ingest::Schedule.entries.to_h { |e| [e.name, Stats.new(next_fire:, buried_streak:)] }
  end

  test "every entry tuber holds is run by tuber, with tuber's next fire" do
    rows(held: all_held).each_value do |row|
      assert_equal :tuber, row.runner, row.entry.name
      assert_equal NOW + 1.minute, row.next_fire
    end
  end

  test "an entry tuber doesn't hold is run by bin/scheduler while its heartbeat is fresh" do
    row = rows(held: {}, fallback: true)["histogram_rollup"]

    assert_equal :scheduler, row.runner
    assert_equal Time.utc(2026, 10, 14, 11, 5), row.next_fire.utc
  end

  test "an entry nothing fires is unscheduled, whatever its last run" do
    ScheduleRun.record!("histogram_rollup", at: NOW - 1.minute)
    row = rows(held: {})["histogram_rollup"]

    assert_equal :nobody, row.runner
    assert_equal :unscheduled, row.state
  end

  test "with tuber unreachable and no fallback, what runs it is unknown, not nothing" do
    row = rows(held: nil)["histogram_rollup"]

    assert_equal :unknown, row.runner
    refute_equal :unscheduled, row.state
  end

  test "an entry whose fires dedupe against a buried job is stuck" do
    row = rows(held: all_held(buried_streak: 3))["histogram_rollup"]

    assert_equal :stuck, row.state
    assert_equal 3, row.buried_streak
  end

  test "a run since the previous due fire is ok" do
    ScheduleRun.record!("histogram_rollup", at: Time.utc(2026, 10, 14, 9, 6))
    assert_equal :ok, rows(held: all_held)["histogram_rollup"].state
  end

  test "one missed fire is allowed for: it may be queued behind another maintenance job" do
    ScheduleRun.record!("histogram_rollup", at: Time.utc(2026, 10, 14, 8, 6))
    # due 09:05 and 10:05 since; the 09:05 one is the run that's missing
    assert_equal :late, rows(held: all_held)["histogram_rollup"].state

    ScheduleRun.record!("histogram_rollup", at: Time.utc(2026, 10, 14, 9, 5, 30))
    assert_equal :ok, rows(held: all_held)["histogram_rollup"].state
  end

  test "an entry with no run on record isn't late until a cycle has passed since boot" do
    # booted 09:30: histogram_rollup was due 10:05 only, so not yet late
    assert_equal :pending, rows(held: all_held)["histogram_rollup"].state
    # monitor_evaluation was due 60 times since boot without a run
    assert_equal :late, rows(held: all_held)["monitor_evaluation"].state
    # weekly deep pass: nowhere near a cycle yet
    assert_equal :pending, rows(held: all_held)["storage_stats_deep"].state
  end

  # --- /_health ---------------------------------------------------------------

  def health(at)
    with_stub(Ingest::ScheduleStatus, :booted_at, -> { BOOTED }) do
      Ingest::ScheduleStatus.health(now: at)
    end
  end

  test "health is ok while monitor_evaluation keeps running" do
    ScheduleRun.record!("monitor_evaluation", at: NOW - 2.minutes)

    result = health(NOW)
    assert_equal "ok", result[:status]
    assert_equal (NOW - 2.minutes).iso8601, result[:last_run_at]
  end

  test "health goes late five minutes after monitor_evaluation last ran" do
    ScheduleRun.record!("monitor_evaluation", at: NOW - 6.minutes)

    assert_equal "late", health(NOW)[:status]
  end

  test "health goes late when nothing has run it since boot, rather than waiting forever" do
    assert_equal "ok", health(BOOTED + 4.minutes)[:status]
    assert_equal "late", health(BOOTED + 6.minutes)[:status]
    assert_nil health(BOOTED + 6.minutes)[:last_run_at]
  end
end

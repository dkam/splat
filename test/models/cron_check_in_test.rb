require "test_helper"

# cron_monitors keeps a monitor's latest check-in; cron_check_ins keeps every
# run, which is what lets a monitor be drawn over time.
class CronCheckInTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  def check_in(status, check_in_id: nil, duration: nil, slug: "recompute-popularity")
    payload = {"monitor_slug" => slug, "status" => status, "check_in_id" => check_in_id,
               "monitor_config" => {"schedule" => {"type" => "crontab", "value" => "30 3 * * *"}, "timezone" => "Australia/Melbourne"}}
    payload["duration"] = duration if duration
    CronMonitor.record_check_in!(payload.compact, @project)
  end

  test "a run's in_progress and its ok fill in one row" do
    started = Time.utc(2026, 10, 17, 16, 30)
    travel_to(started) { check_in("in_progress", check_in_id: "run-1") }
    monitor = travel_to(started + 5029) { check_in("ok", check_in_id: "run-1", duration: 5028.6) }

    run = monitor.check_ins.sole
    assert_equal ["ok", started, started + 5029], [run.status, run.started_at, run.finished_at]
    assert_in_delta 5028.6, run.duration
    assert_equal @project.id, run.project_id
  end

  test "a heartbeat with no in_progress is a row of its own, started duration seconds before it arrived" do
    at = Time.utc(2026, 10, 18, 9, 45, 6)
    monitor = travel_to(at) { check_in("ok", duration: 2.0, slug: "push-to-meili") }
    travel_to(at + 10.minutes) { check_in("error", slug: "push-to-meili") }

    first, second = monitor.check_ins.order(:started_at).to_a
    assert_equal ["ok", at - 2, at, 2.0], [first.status, first.started_at, first.finished_at, first.duration]
    assert_equal ["error", at + 10.minutes, nil], [second.status, second.started_at, second.duration]
  end

  # Check-ins can overtake each other in flight (see CronMonitor.record_check_in!).
  test "an in_progress that arrives after its run finished adds nothing" do
    monitor = check_in("ok", check_in_id: "run-2", duration: 3.0)
    check_in("in_progress", check_in_id: "run-2")

    assert_equal ["ok"], monitor.check_ins.pluck(:status)
  end

  test "a run still going is an open row" do
    monitor = check_in("in_progress", check_in_id: "run-3")

    run = monitor.check_ins.sole
    assert_equal ["in_progress", nil], [run.status, run.finished_at]
  end

  test "a missed check-in is recorded once, at the time it was due" do
    last = Time.utc(2026, 10, 17, 10, 0)
    monitor = CronMonitor.create!(project: @project, slug: "blog-cache", schedule_type: "interval",
      schedule_value: "3", schedule_unit: "hour", checkin_margin: 30, last_status: "ok",
      last_checkin_at: last, last_ok_at: last)

    travel_to(last + 4.hours) { Monitors::EvaluateJob.new.perform }
    travel_to(last + 4.hours + 1.minute) { Monitors::EvaluateJob.new.perform }

    miss = monitor.check_ins.sole
    assert_equal ["missed", last + 3.hours], [miss.status, miss.started_at]
  end

  test "retention retires check-ins on the events clock" do
    monitor = check_in("ok", duration: 1.0)
    old = travel_to(Setting.instance.events_data_cutoff_date - 1.day) { check_in("ok", duration: 1.0) }.check_ins.order(:started_at).first

    result = Maintenance::RetentionJob.new.perform

    assert_equal 1, result[:check_ins_deleted]
    assert_not CronCheckIn.exists?(old.id)
    assert_equal 1, monitor.check_ins.count
  end

  test "deleting a monitor deletes its runs" do
    monitor = check_in("ok", duration: 1.0)

    assert_difference -> { CronCheckIn.count }, -1 do
      monitor.destroy!
    end
  end
end

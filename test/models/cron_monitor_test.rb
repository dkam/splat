require "test_helper"

class CronMonitorTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  def heartbeat_payload(overrides = {})
    {
      "check_in_id" => "83a7c03ed0a04e1b97e2e3b18d38f244",
      "monitor_slug" => "meili-flush",
      "status" => "ok",
      "duration" => 0.4,
      "environment" => "production",
      "monitor_config" => {
        "schedule" => {"type" => "interval", "value" => 1, "unit" => "minute"},
        "checkin_margin" => 5,
        "max_runtime" => 30,
        "timezone" => "Etc/UTC"
      }
    }.merge(overrides)
  end

  test "record_check_in! auto-registers a monitor from monitor_config" do
    monitor = nil
    assert_difference -> { CronMonitor.count }, 1 do
      monitor = CronMonitor.record_check_in!(heartbeat_payload, @project)
    end

    assert_equal "meili-flush", monitor.slug
    assert_equal "interval", monitor.schedule_type
    assert_equal "1", monitor.schedule_value
    assert_equal "minute", monitor.schedule_unit
    assert_equal 5, monitor.checkin_margin
    assert_equal 30, monitor.max_runtime
    assert_equal "ok", monitor.last_status
    assert_equal "production", monitor.environment
    assert_in_delta 0.4, monitor.last_duration
    assert monitor.last_ok_at.present?
    assert_nil monitor.in_progress_since
  end

  test "record_check_in! upserts the same slug instead of creating rows" do
    CronMonitor.record_check_in!(heartbeat_payload, @project)
    assert_no_difference -> { CronMonitor.count } do
      CronMonitor.record_check_in!(heartbeat_payload("duration" => 1.2), @project)
    end
    assert_in_delta 1.2, CronMonitor.find_by!(project: @project, slug: "meili-flush").last_duration
  end

  test "record_check_in! without monitor_config still tracks last seen" do
    monitor = CronMonitor.record_check_in!(
      {"monitor_slug" => "bare", "status" => "ok"}, @project
    )
    assert_nil monitor.schedule_type
    assert monitor.last_checkin_at.present?
    refute monitor.missed?(10.years.from_now), "no schedule → never missed"
  end

  test "record_check_in! rejects junk" do
    assert_nil CronMonitor.record_check_in!({"status" => "ok"}, @project)
    assert_nil CronMonitor.record_check_in!({"monitor_slug" => "x", "status" => "bogus"}, @project)
    assert_nil CronMonitor.record_check_in!("not a hash", @project)
  end

  test "in_progress starts the overrun clock; ok clears it" do
    monitor = CronMonitor.record_check_in!(heartbeat_payload("status" => "in_progress"), @project)
    assert monitor.in_progress_since.present?
    refute monitor.overrun?(monitor.in_progress_since + 29.minutes)
    assert monitor.overrun?(monitor.in_progress_since + 31.minutes)

    monitor = CronMonitor.record_check_in!(heartbeat_payload("status" => "ok"), @project)
    assert_nil monitor.in_progress_since
    refute monitor.overrun?(1.day.from_now)
  end

  test "missed? honours interval plus margin" do
    monitor = CronMonitor.record_check_in!(heartbeat_payload, @project)

    # 1 minute interval + 5 minute margin
    refute monitor.missed?(monitor.last_checkin_at + 5.minutes)
    assert monitor.missed?(monitor.last_checkin_at + 7.minutes)
  end

  test "missed? uses the default margin when monitor_config omits it" do
    payload = heartbeat_payload
    payload["monitor_config"].delete("checkin_margin")
    monitor = CronMonitor.record_check_in!(payload, @project)

    refute monitor.missed?(monitor.last_checkin_at + 90.seconds)
    assert monitor.missed?(monitor.last_checkin_at + 3.minutes)
  end

  test "missed? counts an error check-in as checking in" do
    monitor = CronMonitor.record_check_in!(heartbeat_payload("status" => "error"), @project)
    refute monitor.missed?(monitor.last_checkin_at + 5.minutes)
    assert monitor.erroring?
  end

  test "crontab schedules evaluate via fugit" do
    payload = heartbeat_payload(
      "monitor_slug" => "nightly",
      "monitor_config" => {
        "schedule" => {"type" => "crontab", "value" => "0 2 * * *"},
        "checkin_margin" => 10,
        "timezone" => "Etc/UTC"
      }
    )
    monitor = CronMonitor.record_check_in!(payload, @project)

    next_two_am = monitor.next_expected_at
    assert_equal 2, next_two_am.utc.hour
    refute monitor.missed?(next_two_am + 5.minutes)
    assert monitor.missed?(next_two_am + 11.minutes)
  end

  # Regression: every zoned crontab monitor was reported missed daily while
  # running exactly on time. `basis.in_time_zone(tz)` looked like it applied the
  # zone, but fugit only ever reads one from the cron expression, so the
  # schedule was evaluated against UTC. The real case: DeadShopSweepJob runs at
  # 03:45 Melbourne, checks in at 17:45Z, and UTC scored that 14 hours late.
  test "crontab schedules are evaluated in the monitor's declared timezone" do
    payload = heartbeat_payload(
      "monitor_slug" => "dead-shop-sweep",
      "monitor_config" => {
        "schedule" => {"type" => "crontab", "value" => "45 3 * * *"},
        "checkin_margin" => 60,
        "timezone" => "Australia/Melbourne"
      }
    )
    monitor = CronMonitor.record_check_in!(payload, @project)
    # 03:45 Melbourne on the 16th, the check-in the job actually sends.
    monitor.update!(last_checkin_at: Time.utc(2026, 8, 15, 17, 45, 1))

    # Next run is 03:45 Melbourne on the 17th — 17:45Z, not 03:45Z.
    assert_equal Time.utc(2026, 8, 16, 17, 45), monitor.next_expected_at.utc
    refute monitor.missed?(Time.utc(2026, 8, 16, 13, 20)), "on time, mid-interval"
    refute monitor.missed?(Time.utc(2026, 8, 16, 18, 30)), "inside the 60m margin"
    assert monitor.missed?(Time.utc(2026, 8, 16, 19, 0)), "genuinely late"
  end

  test "an unknown timezone leaves the schedule unevaluable rather than missed" do
    payload = heartbeat_payload(
      "monitor_slug" => "bogus-zone",
      "monitor_config" => {
        "schedule" => {"type" => "crontab", "value" => "45 3 * * *"},
        "timezone" => "Mars/Olympus_Mons"
      }
    )
    monitor = CronMonitor.record_check_in!(payload, @project)
    assert_nil monitor.next_expected_at
    refute monitor.missed?(1.year.from_now)
  end

  test "unparsable schedules never fire missed?" do
    payload = heartbeat_payload(
      "monitor_config" => {"schedule" => {"type" => "crontab", "value" => "not a cron"}}
    )
    monitor = CronMonitor.record_check_in!(payload, @project)
    assert_nil monitor.next_expected_at
    refute monitor.missed?(1.year.from_now)
  end
end

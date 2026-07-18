require "test_helper"

class Monitors::EvaluateJobTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @job = Monitors::EvaluateJob.new
  end

  def create_monitor(overrides = {})
    CronMonitor.create!({
      project: @project,
      slug: "meili-flush",
      schedule_type: "interval",
      schedule_value: "1",
      schedule_unit: "minute",
      checkin_margin: 5,
      last_status: "ok",
      last_checkin_at: Time.current,
      last_ok_at: Time.current
    }.merge(overrides))
  end

  def monitor_issue(kind)
    Issue.find_by(project_id: @project.id, fingerprint: "monitor:meili-flush:#{kind}")
  end

  test "opens an issue when a monitor misses its check-in" do
    monitor = create_monitor(last_checkin_at: 10.minutes.ago, last_ok_at: 10.minutes.ago)

    assert_difference -> { Issue.count }, 1 do
      @job.perform
    end

    issue = monitor_issue("missed")
    assert issue.open?
    assert_equal "MonitorMissed", issue.exception_type
    assert_match "meili-flush", issue.title
    assert_equal "missed", monitor.reload.state
  end

  test "does not re-fire while the issue is open" do
    create_monitor(last_checkin_at: 10.minutes.ago, last_ok_at: 10.minutes.ago)
    @job.perform

    assert_no_difference -> { Issue.count } do
      @job.perform
    end
  end

  test "a healthy monitor within its window opens nothing" do
    monitor = create_monitor

    assert_no_difference -> { Issue.count } do
      @job.perform
    end
    assert_equal "ok", monitor.reload.state
  end

  test "recovery resolves the open issue and a later miss reopens it" do
    monitor = create_monitor(last_checkin_at: 10.minutes.ago, last_ok_at: 10.minutes.ago)
    @job.perform
    issue = monitor_issue("missed")
    assert issue.open?

    # Heartbeat comes back.
    monitor.update!(last_checkin_at: Time.current, last_ok_at: Time.current)
    @job.perform
    assert issue.reload.resolved?
    assert_equal "ok", monitor.reload.state

    # Goes silent again: same issue reopens, no duplicate.
    monitor.update!(last_checkin_at: 10.minutes.ago)
    assert_no_difference -> { Issue.count } do
      @job.perform
    end
    assert issue.reload.open?
  end

  test "ignored issues stay ignored" do
    monitor = create_monitor(last_checkin_at: 10.minutes.ago, last_ok_at: 10.minutes.ago)
    @job.perform
    monitor_issue("missed").ignored!

    @job.perform
    assert monitor_issue("missed").ignored?

    # Recovery doesn't resolve an ignored issue either.
    monitor.update!(last_checkin_at: Time.current, last_ok_at: Time.current)
    @job.perform
    assert monitor_issue("missed").ignored?
  end

  test "an error check-in opens an error issue" do
    monitor = create_monitor(last_status: "error")

    @job.perform

    issue = monitor_issue("error")
    assert issue.open?
    assert_equal "MonitorError", issue.exception_type
    assert_equal "error", monitor.reload.state
  end

  test "a stuck in_progress run opens an overrun issue" do
    monitor = create_monitor(
      last_status: "in_progress",
      in_progress_since: 45.minutes.ago,
      max_runtime: 30
    )

    @job.perform

    issue = monitor_issue("overrun")
    assert issue.open?
    assert_equal "MonitorOverrun", issue.exception_type
    assert_equal "overrun", monitor.reload.state
  end

  test "a monitor that never checked in and has no schedule stays unknown" do
    monitor = create_monitor(
      last_status: nil, last_checkin_at: nil, last_ok_at: nil,
      schedule_type: nil, schedule_value: nil, schedule_unit: nil
    )

    assert_no_difference -> { Issue.count } do
      @job.perform
    end
    assert_equal "unknown", monitor.reload.state
  end
end

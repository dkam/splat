require "test_helper"

class MonitorsControllerTest < ActionDispatch::IntegrationTest
  # Auth is a no-op unless OIDC is configured, so these hit the real controller.
  setup do
    @project = projects(:one)
  end

  test "index renders monitors with schedule and state" do
    CronMonitor.create!(
      project: @project, slug: "meili-flush",
      schedule_type: "interval", schedule_value: "1", schedule_unit: "minute",
      checkin_margin: 5, last_status: "ok", last_checkin_at: 2.minutes.ago,
      last_ok_at: 2.minutes.ago, last_duration: 0.4, environment: "production",
      state: "ok"
    )

    get project_monitors_url(@project.slug)
    assert_response :success
    assert_match "meili-flush", response.body
    assert_match "every 1 minute", response.body
  end

  test "index renders the empty state" do
    get project_monitors_url(@project.slug)
    assert_response :success
    assert_match "No monitors yet", response.body
  end

  def daily(slug, **options)
    CronMonitor.create!(project: @project, slug: slug, schedule_type: "crontab", schedule_value: "0 3 * * *",
      checkin_margin: 60, created_at: 30.days.ago, **options)
  end

  test "index opens on a week, each monitor's runs kept against its schedule" do
    travel_to Time.utc(2026, 10, 18, 10, 4)
    nightly = daily("nightly", state: "ok", last_checkin_at: 7.hours.ago)
    days = (0..9).map { Time.utc(2026, 10, 18, 3) - it.days }
    CronCheckIn.insert_all(days.map { {cron_monitor_id: nightly.id, project_id: @project.id, status: "ok", started_at: it, finished_at: it + 60, duration: 60, created_at: it} })

    get project_monitors_url(@project.slug)
    assert_response :success
    assert_select "nav[aria-label=Window] a[aria-current=page]", text: "7d"
    assert_select "[data-monitor-row=nightly] [data-on-time]", text: "7/7 on time"
    assert_select "[data-monitor-row=nightly]", text: /daily 03:00/
  end

  # A monitor long gone quiet misses every check-in in the window: counted,
  # it would bury the one miss worth seeing.
  test "the Missed row counts what was missed, but not by a monitor gone quiet" do
    travel_to Time.utc(2026, 10, 18, 10, 4)
    # Seven days with no run each, for two monitors: the one with a check-in
    # kept 20 days back says what's known, and the late one.
    CronCheckIn.create!(cron_monitor: daily("history"), project_id: @project.id, status: "ok", started_at: 20.days.ago)
    daily("late", state: "missed", last_checkin_at: 2.days.ago)
    daily("retired", state: "missed", last_checkin_at: 40.days.ago)

    get project_monitors_url(@project.slug)
    assert_select "[data-signal=missed] [data-count]", text: "14"
    assert_select "[data-group=quiet] + [data-monitor-row=retired]"
  end

  test "each monitor's row has a delete button that asks first" do
    nightly = daily("nightly", state: "ok")

    get project_monitors_url(@project.slug)
    assert_select "[data-monitor-row=nightly] form[action=?][data-turbo-confirm]", project_monitor_path(@project.slug, nightly)
  end

  test "destroy deletes the monitor, resolves its open issue, and returns to the window it was in" do
    retired = daily("detailer", state: "missed", last_checkin_at: 40.days.ago)
    nightly = daily("nightly", state: "ok")
    issue = Issue.create!(project: @project, fingerprint: "monitor:detailer:missed", title: "Monitor missed check-in: detailer",
      exception_type: "MonitorMissed", status: :open, first_seen: 40.days.ago, last_seen: 40.days.ago)

    delete project_monitor_url(@project.slug, retired), headers: {"Referer" => project_monitors_url(@project.slug, window: "30d")}

    assert_redirected_to project_monitors_url(@project.slug, window: "30d")
    refute CronMonitor.exists?(retired.id)
    assert CronMonitor.exists?(nightly.id)
    assert issue.reload.resolved?
  end

  test "destroy won't reach another project's monitor" do
    other = CronMonitor.create!(project: projects(:two), slug: "nightly", state: "ok")

    delete project_monitor_url(@project.slug, other)
    assert_response :not_found
    assert CronMonitor.exists?(other.id)
  end

  test "the overview's Monitors heading opens this page in its window" do
    daily("nightly", state: "ok")

    get project_url(@project.slug, window: "24h")
    assert_select "a[href=?]", project_monitors_path(@project.slug, window: "24h"), text: "Monitors"
  end
end

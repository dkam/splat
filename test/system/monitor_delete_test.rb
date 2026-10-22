require "application_system_test_case"

# The delete button asks before it goes (Turbo's confirm, which only a browser
# runs), then lands back on the monitors page in the window it was in.
class MonitorDeleteTest < ApplicationSystemTestCase
  setup do
    @project = projects(:one)
    daily = {schedule_type: "crontab", schedule_value: "0 3 * * *", checkin_margin: 60, created_at: 60.days.ago}
    CronMonitor.create!(project: @project, slug: "detailer", state: "missed", last_checkin_at: 40.days.ago, **daily)
    CronMonitor.create!(project: @project, slug: "nightly", state: "ok", last_checkin_at: 7.hours.ago, **daily)
  end

  test "deleting a monitor asks first, then returns to its window without it" do
    visit project_monitors_path(@project.slug, window: "30d")

    dismiss_confirm { within("[data-monitor-row=detailer]") { click_on "Delete monitor" } }
    assert_selector "[data-monitor-row=detailer]"

    accept_confirm(/Delete monitor detailer\?/) { within("[data-monitor-row=detailer]") { click_on "Delete monitor" } }
    assert_no_selector "[data-monitor-row=detailer]"
    assert_selector "[data-monitor-row=nightly]"
    assert_current_path project_monitors_path(@project.slug, window: "30d")
  end
end

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
end

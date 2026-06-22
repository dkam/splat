require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  # Auth is a no-op unless OIDC is configured, so these hit the real controller.
  setup do
    @project = projects(:one)
  end

  test "show renders with the logs quick-link card" do
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "sentry", body: "x", payload: {})

    get project_url(@project.slug)
    assert_response :success
    assert_match "Logs (24h)", response.body
    assert_select "a[href=?]", project_logs_path(@project.slug)
  end
end

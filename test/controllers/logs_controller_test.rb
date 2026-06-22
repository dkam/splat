require "test_helper"

class LogsControllerTest < ActionDispatch::IntegrationTest
  # Auth is a no-op unless OIDC is configured, so these hit the real controller.
  setup do
    @project = projects(:one)
    @log = Log.create!(
      project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :error, source: "sentry", body: "controller test log",
      trace_id: "ctrl-trace", logger_name: "rails", environment: "production",
      payload: {"body" => "controller test log", "attributes" => {"k" => "v"}}
    )
  end

  test "index renders the stream" do
    get project_logs_url(@project.slug)
    assert_response :success
    assert_match "controller test log", response.body
  end

  test "index filters by level" do
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :debug, source: "sentry", body: "noisy debug line", payload: {})

    get project_logs_url(@project.slug, level: "error")
    assert_response :success
    assert_match "controller test log", response.body
    refute_match "noisy debug line", response.body
  end

  test "index filters by trace_id" do
    get project_logs_url(@project.slug, trace_id: "ctrl-trace")
    assert_response :success
    assert_match "controller test log", response.body
  end

  test "show renders a single log with attributes" do
    get project_log_url(@project.slug, @log)
    assert_response :success
    assert_match "controller test log", response.body
    assert_match "Attributes", response.body
  end
end

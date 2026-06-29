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

  test "index paginates with countless prev/next nav across pages" do
    # One page holds 50; create enough to force a second page.
    60.times do |i|
      Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: i.seconds.ago,
        level: :info, source: "sentry", body: "page fill #{i}", payload: {})
    end

    # Page 1: a Next link, Prev disabled.
    get project_logs_url(@project.slug)
    assert_response :success
    assert_match "Next ›", response.body
    assert_select "a[rel=next]", 1
    assert_select "span[aria-disabled=true]", text: /Prev/

    # Page 2: a working Prev link back.
    get project_logs_url(@project.slug, page: 2)
    assert_response :success
    assert_select "a[rel=prev]", 1
  end

  test "show renders a single log with attributes" do
    get project_log_url(@project.slug, @log)
    assert_response :success
    assert_match "controller test log", response.body
    assert_match "Attributes", response.body
  end
end

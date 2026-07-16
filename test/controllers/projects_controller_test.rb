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

  test "show offers a DSN pointing at the requested authority when SPLAT_HOST is unset" do
    # Without .env (a fresh clone), a server on a non-default port used to hand
    # out a hardcoded localhost:3000 DSN.
    original = ENV.delete("SPLAT_HOST")

    get project_url(@project.slug), headers: {"HOST" => "localhost:3031"}

    assert_response :success
    assert_select "[data-clipboard-text-value=?]", "http://#{@project.public_key}@localhost:3031/#{@project.slug}"
  ensure
    ENV["SPLAT_HOST"] = original
  end

  test "show prefers SPLAT_HOST over the requested authority" do
    # The externally reachable host can differ from the one being browsed.
    original = ENV["SPLAT_HOST"]
    ENV["SPLAT_HOST"] = "splat.example.com"

    get project_url(@project.slug), headers: {"HOST" => "localhost:3031"}

    assert_response :success
    assert_select "[data-clipboard-text-value=?]", "https://#{@project.public_key}@splat.example.com/#{@project.slug}"
  ensure
    ENV["SPLAT_HOST"] = original
  end
end

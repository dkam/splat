# frozen_string_literal: true

require "test_helper"

# The tri-state OIDC configuration gate.
#
# The state that matters here is :misconfigured — some OIDC variables set but
# not all. Before this existed a typo'd OIDC_CLIENT_SECRET made oidc_configured?
# false, which silently served the whole UI unauthenticated *and* changed how
# MCP authenticates (Mcp::McpController#mcp_auth_outcome), with nothing in the
# logs and nothing visible in the UI.
class AuthConfigTest < ActionDispatch::IntegrationTest
  # ---- state derivation -------------------------------------------------

  test "no OIDC variables is :open" do
    with_oidc_env({}) do
      assert_equal :open, SplatAuthorization.oidc_state
      assert_not SplatAuthorization.oidc_configured?
      assert_not SplatAuthorization.oidc_misconfigured?
    end
  end

  test "all three OIDC variables is :enforcing" do
    with_oidc_env(full_oidc_env) do
      assert_equal :enforcing, SplatAuthorization.oidc_state
      assert SplatAuthorization.oidc_configured?
      assert_not SplatAuthorization.oidc_misconfigured?
      assert_empty SplatAuthorization.missing_oidc_vars
    end
  end

  test "a missing OIDC variable is :misconfigured, not :open" do
    with_oidc_env(full_oidc_env.except("OIDC_CLIENT_SECRET")) do
      assert_equal :misconfigured, SplatAuthorization.oidc_state
      assert_not SplatAuthorization.oidc_configured?
      assert SplatAuthorization.oidc_misconfigured?
      assert_equal ["OIDC_CLIENT_SECRET"], SplatAuthorization.missing_oidc_vars
    end
  end

  test "a blank OIDC variable counts as missing" do
    with_oidc_env(full_oidc_env.merge("OIDC_DISCOVERY_URL" => "")) do
      assert_equal :misconfigured, SplatAuthorization.oidc_state
      assert_equal ["OIDC_DISCOVERY_URL"], SplatAuthorization.missing_oidc_vars
    end
  end

  test "an allowlist with no provider is flagged but stays :open" do
    with_oidc_env({"SPLAT_ALLOWED_DOMAINS" => "example.com"}) do
      assert_equal :open, SplatAuthorization.oidc_state
      assert SplatAuthorization.allowlist_without_provider?
    end
  end

  # ---- what a half-configured instance serves ---------------------------

  test "half-configured refuses the UI with a 503 naming the missing variable" do
    with_oidc_env(full_oidc_env.except("OIDC_CLIENT_ID")) do
      get root_path

      assert_response :service_unavailable
      assert_match(/OIDC_CLIENT_ID/, @response.body)
    end
  end

  test "half-configured refuses non-HTML requests with a bare 503" do
    with_oidc_env(full_oidc_env.except("OIDC_CLIENT_ID")) do
      get root_path, headers: {"Accept" => "application/json"}

      assert_response :service_unavailable
      assert_empty @response.body
    end
  end

  # The whole reason the 503 lives in require_authentication rather than a
  # global filter: everything that ingests data skips that filter, so a deploy
  # typo costs you the UI, not your production error events.
  test "half-configured keeps accepting events" do
    project = Project.create!(name: "Ingest", slug: "ingest-#{SecureRandom.hex(4)}",
      public_key: "key-#{SecureRandom.hex(8)}")

    with_oidc_env(full_oidc_env.except("OIDC_CLIENT_SECRET")) do
      post "/api/#{project.slug}/envelope?sentry_key=#{project.public_key}",
        headers: {"Content-Type" => "application/octet-stream"},
        params: sample_envelope

      assert_response :success
    end
  end

  test "half-configured keeps serving the health check" do
    with_oidc_env(full_oidc_env.except("OIDC_DISCOVERY_URL")) do
      get "/_health"
      assert_response :success
    end
  end

  # ---- the login page ---------------------------------------------------

  test "login page 503s and names the missing variables when half-configured" do
    with_oidc_env(full_oidc_env.except("OIDC_CLIENT_SECRET", "OIDC_DISCOVERY_URL")) do
      get login_path

      assert_response :service_unavailable
      assert_match(/Half-Configured/i, @response.body)
      assert_match(/OIDC_CLIENT_SECRET/, @response.body)
      assert_match(/OIDC_DISCOVERY_URL/, @response.body)
    end
  end

  # Deliberately open is Splat's documented default, not a fault — it should
  # not look like an outage.
  test "login page 200s and explains itself when auth is deliberately off" do
    with_oidc_env({}) do
      get login_path

      assert_response :success
      assert_match(/Authentication Not Enabled/i, @response.body)
    end
  end

  # An empty allowlist denies everyone (correctly). Without this warning you
  # discover that only after a full provider round trip, via a message that
  # blames the user's email rather than the missing variable.
  test "login page warns when configured with no allowlist" do
    with_oidc_env(full_oidc_env) do
      get login_path

      assert_response :success
      assert_match(/No allowlist configured/i, @response.body)
      assert_match(/SPLAT_ALLOWED_USERS/, @response.body)
    end
  end

  test "login page does not warn once an allowlist is set" do
    with_oidc_env(full_oidc_env.merge("SPLAT_ALLOWED_DOMAINS" => "example.com")) do
      get login_path

      assert_response :success
      assert_no_match(/No allowlist configured/i, @response.body)
    end
  end

  private

  def full_oidc_env
    {
      "OIDC_CLIENT_ID" => "splat-test",
      "OIDC_CLIENT_SECRET" => "s3cret",
      "OIDC_DISCOVERY_URL" => "https://idp.example.com/.well-known/openid-configuration"
    }
  end

  # Set exactly the given auth variables and clear every other one, so a test
  # never inherits a developer's real .env. SplatAuthorization memoizes the
  # parsed allowlist across requests, so that has to be reset on both sides.
  def with_oidc_env(vars)
    managed = SplatAuthorization::OIDC_VARS + SplatAuthorization::ALLOWLIST_VARS
    original = managed.index_with { |var| ENV[var] }

    managed.each { |var| ENV.delete(var) }
    vars.each { |var, value| ENV[var] = value }
    reset_allowlist_memo!

    yield
  ensure
    original.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
    reset_allowlist_memo!
  end

  def reset_allowlist_memo!
    SplatAuthorization.instance_variable_set(:@allowed_emails, nil)
    SplatAuthorization.instance_variable_set(:@allowed_domains, nil)
  end

  def sample_envelope
    [
      {"event_id" => SecureRandom.uuid, "sent_at" => Time.current.iso8601}.to_json,
      {"type" => "event", "length" => 100}.to_json,
      {"timestamp" => Time.current.iso8601, "message" => "half-configured ingest",
       "level" => "error", "platform" => "ruby"}.to_json
    ].join("\n")
  end
end

require "test_helper"

class OidcLogoutControllerTest < ActionDispatch::IntegrationTest
  # OIDC backchannel logout (POST /oidc/logout -> OidcAuth#backchannel_logout).
  # A real logout flow needs a signed logout_token from the provider; here we
  # assert the endpoint exists and rejects a request with no token.

  test "rejects backchannel logout without a logout_token" do
    post oidc_logout_url
    assert_response :bad_request
    assert_match(/Missing logout_token/, @response.body)
  end

  # A signed logout_token is impractical to forge here, so exercise the step that
  # matters for MCP — invalidating the session also revokes that user's MCP token
  # immediately, rather than leaving it live until the TTL lapses.
  test "backchannel logout expires the user's MCP token" do
    OidcSession.create!(oidc_sid: "sid-x", session_id: "s-x",
      user_email: "dev@example.com", expires_at: 1.hour.from_now)
    token = McpToken.for("dev@example.com")
    assert_not_nil token.last_authenticated_at

    terminated = OidcAuthController.new.send(:process_backchannel_logout, {"sid" => "sid-x"})

    assert_equal 1, terminated
    assert_nil token.reload.last_authenticated_at
  end
end

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
end

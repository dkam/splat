require "test_helper"

class OidcLogoutControllerTest < ActionDispatch::IntegrationTest
  test "should get logout" do
    get oidc_logout_logout_url
    assert_response :success
  end
end

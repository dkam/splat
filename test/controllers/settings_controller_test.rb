require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  # Auth is a no-op unless OIDC is configured (Authentication#require_authentication),
  # so these hit the real controller directly in the test env.

  test "index renders" do
    get settings_url
    assert_response :success
  end

  test "update with valid params redirects and persists" do
    put settings_url, params: {setting: {burst_threshold: 2500}}
    assert_redirected_to settings_path
    assert_equal "Settings updated successfully.", flash[:notice]
    assert_equal 2500, Setting.instance.reload.burst_threshold
  end

  test "update rejects an invalid ntfy_url" do
    put settings_url, params: {setting: {ntfy_url: "not a url"}}
    assert_redirected_to settings_path
    assert_match(/Error updating settings/, flash[:alert])
  end
end

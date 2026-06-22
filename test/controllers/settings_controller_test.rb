require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  # Auth is a no-op unless OIDC is configured (Authentication#require_authentication),
  # so these hit the real controller directly in the test env.

  test "index renders" do
    get settings_url
    assert_response :success
  end

  test "index renders the compression panel when a snapshot has one" do
    # Regression: the compression branch references StorageStats::COMPRESSION_SAMPLE
    # and only renders when the snapshot carries compression data — an empty-cache
    # render (the test above) never exercises it. Stub a populated snapshot so
    # this branch (and that constant reference) actually renders.
    snapshot = {
      groups: [{name: "Logs", base: "LogsRecord",
                tables: [{name: "logs", row_estimate: 10, table_bytes: 100, index_bytes: 50, total_bytes: 150}]}],
      total: 150,
      compression: [{name: "Logs", rows: 10, sample: 10, ratio: 3.5,
                     stored_bytes: 100, original_bytes: 350, saved_bytes: 250}],
      collected_at: Time.current
    }

    Rails.cache.write(StorageStats::CACHE_KEY, snapshot)
    get settings_url
    assert_response :success
    assert_match "Compression", response.body
    assert_match "sampled rows per table", response.body # the line 114 that used to crash
  ensure
    Rails.cache.delete(StorageStats::CACHE_KEY)
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

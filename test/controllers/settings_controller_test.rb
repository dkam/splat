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

  # --- MCP panel, without OIDC: one shared instance token ---------------------

  test "index offers the shared instance token when there is no OIDC" do
    get settings_url

    assert_response :success
    assert_match(/claude mcp add --transport http/, response.body)
    assert_match(/#{Regexp.escape(Setting.instance.reload.mcp_token)}/, response.body)
    assert_equal 0, McpToken.count, "no users, so no per-user rows"
  end

  test "index mints the instance token lazily, not before it is asked for" do
    assert_nil Setting.instance.mcp_token

    get settings_url

    assert_not_nil Setting.instance.reload.mcp_token
  end

  test "reset_mcp_token regenerates the instance token without OIDC" do
    get settings_url
    was = Setting.instance.reload.mcp_token

    post reset_mcp_token_url

    assert_redirected_to settings_path
    assert_match(/regenerated/, flash[:notice])
    assert_not_equal was, Setting.instance.reload.mcp_token
  end

  # --- MCP panel, with OIDC: per-user tokens ----------------------------------

  test "index shows a personal token, not the instance one, when OIDC is on" do
    with_oidc do
      with_allowlist("dev@example.com") do
        signed_in_as("dev@example.com") do
          get settings_url
        end
      end
    end

    assert_response :success
    token = McpToken.sole
    assert_match(/claude mcp add --transport http/, response.body)
    assert_match(/#{Regexp.escape(token.token)}/, response.body)
    assert_nil Setting.instance.reload.mcp_token, "the shared token is retired under OIDC"
  end

  test "an authenticated web visit renews the MCP token's authentication stamp" do
    with_oidc do
      with_allowlist("dev@example.com") do
        signed_in_as("dev@example.com") do
          token = McpToken.for("dev@example.com")
          token.update_column(:last_authenticated_at, 3.days.ago)

          get settings_url

          assert token.reload.last_authenticated_at > 1.minute.ago,
            "loading a page while signed in should push the stamp forward"
        end
      end
    end
  end

  test "index withholds the token from a signed-in user who has left the allowlist" do
    with_oidc do
      with_allowlist("someone-else@example.com") do
        signed_in_as("dev@example.com") do
          get settings_url
        end
      end
    end

    assert_response :success
    assert_no_match(/claude mcp add/, response.body)
    assert_equal 0, McpToken.count
  end

  test "reset_mcp_token issues a new token for the signed-in user" do
    was = nil

    with_oidc do
      with_allowlist("dev@example.com") do
        signed_in_as("dev@example.com") do
          was = McpToken.for("dev@example.com").token
          post reset_mcp_token_url
        end
      end
    end

    assert_redirected_to settings_path
    assert_match(/regenerated/, flash[:notice])
    assert_not_equal was, McpToken.sole.token
  end

  test "reset_mcp_token sends an anonymous visitor to login when OIDC is on" do
    with_oidc do
      post reset_mcp_token_url
    end

    assert_redirected_to login_path
    assert_equal 0, McpToken.count, "the action is never reached"
  end

  test "reset_mcp_token refuses a signed-in user who has left the allowlist" do
    with_oidc do
      with_allowlist("someone-else@example.com") do
        signed_in_as("dev@example.com") do
          post reset_mcp_token_url
        end
      end
    end

    assert_redirected_to settings_path
    assert_match(/allowlist/, flash[:alert])
    assert_equal 0, McpToken.count
  end

  private

  # Integration tests can't populate the session directly, and there's no login
  # route without a real OIDC provider — so shadow the Authentication methods
  # the MCP panel and require_authentication consult, then restore.
  def signed_in_as(email)
    SettingsController.define_method(:authenticated?) { true }
    SettingsController.define_method(:current_user_email) { email }
    SettingsController.define_method(:oidc_session_valid?) { true }
    yield
  ensure
    SettingsController.remove_method(:authenticated?)
    SettingsController.remove_method(:current_user_email)
    SettingsController.remove_method(:oidc_session_valid?)
  end

  # oidc_configured? reads ENV every call, so stubbing it is enough — no memo.
  def with_oidc(&block)
    with_stub(SplatAuthorization, :oidc_configured?, -> { true }, &block)
  end

  # SplatAuthorization memoizes the parsed allowlist across requests.
  def with_allowlist(emails)
    ENV["SPLAT_ALLOWED_USERS"] = emails
    reset_allowlist_memo!
    yield
  ensure
    ENV.delete("SPLAT_ALLOWED_USERS")
    reset_allowlist_memo!
  end

  def reset_allowlist_memo!
    SplatAuthorization.instance_variable_set(:@allowed_emails, nil)
    SplatAuthorization.instance_variable_set(:@allowed_domains, nil)
  end
end

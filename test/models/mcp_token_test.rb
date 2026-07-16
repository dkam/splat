# frozen_string_literal: true

require "test_helper"

class McpTokenTest < ActiveSupport::TestCase
  setup do
    @allowed = "dev@example.com"
    ENV["SPLAT_ALLOWED_USERS"] = @allowed
    reset_allowlist_memo!
  end

  teardown do
    ENV.delete("SPLAT_ALLOWED_USERS")
    reset_allowlist_memo!
  end

  test "for mints a token once per email and reuses it" do
    first = McpToken.for(@allowed)

    assert_equal 64, first.token.length
    assert_equal first, McpToken.for(@allowed)
    assert_equal first.token, McpToken.for(@allowed).token
  end

  test "for normalizes the email so case and padding don't mint duplicates" do
    token = McpToken.for(@allowed)

    assert_equal token, McpToken.for("  DEV@Example.COM  ")
    assert_equal 1, McpToken.count
  end

  test "reset! replaces the token, keeping the row" do
    token = McpToken.for(@allowed)
    was = token.token

    token.reset!

    assert_not_equal was, token.reload.token
    assert_equal 1, McpToken.count
    assert_nil McpToken.authenticate(was), "the old token must stop working"
  end

  test "authenticate returns the token for an allowlisted owner" do
    token = McpToken.for(@allowed)

    assert_equal token, McpToken.authenticate(token.token)
  end

  test "authenticate rejects a token whose owner has left the allowlist" do
    token = McpToken.for(@allowed)

    # The revocation path: no row is deleted, the allowlist simply changes.
    ENV["SPLAT_ALLOWED_USERS"] = "someone-else@example.com"
    reset_allowlist_memo!

    assert_nil McpToken.authenticate(token.token)
    assert McpToken.exists?(token.id), "the row survives; only access is revoked"
  end

  test "authenticate rejects unknown and blank tokens" do
    assert_nil McpToken.authenticate("nope-#{SecureRandom.hex(8)}")
    assert_nil McpToken.authenticate("")
    assert_nil McpToken.authenticate(nil)
  end

  test "touch_last_used! records first use then throttles" do
    token = McpToken.for(@allowed)
    assert_nil token.last_used_at

    McpToken.authenticate(token.token)
    first_use = token.reload.last_used_at
    assert_not_nil first_use

    # A second call inside the window must not write again.
    McpToken.authenticate(token.token)
    assert_equal first_use, token.reload.last_used_at

    token.update_column(:last_used_at, (McpToken::TOUCH_AFTER + 1.minute).ago)
    McpToken.authenticate(token.token)
    assert token.reload.last_used_at > first_use - 1.second
  end

  private

  # SplatAuthorization memoizes the parsed allowlist across requests.
  def reset_allowlist_memo!
    SplatAuthorization.instance_variable_set(:@allowed_emails, nil)
    SplatAuthorization.instance_variable_set(:@allowed_domains, nil)
  end
end

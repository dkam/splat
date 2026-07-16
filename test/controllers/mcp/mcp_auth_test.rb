# frozen_string_literal: true

require "test_helper"

module Mcp
  # Who gets in to /mcp. The endpoint skips browser auth entirely, so this
  # bearer check is the only thing guarding read *and* write tools.
  class McpAuthTest < ActionDispatch::IntegrationTest
    setup do
      @instance_token = "instance-#{SecureRandom.hex(8)}"
      ENV["MCP_AUTH_TOKEN"] = @instance_token
      ENV["SPLAT_ALLOWED_USERS"] = "dev@example.com"
      reset_allowlist_memo!
    end

    teardown do
      ENV.delete("MCP_AUTH_TOKEN")
      ENV.delete("SPLAT_ALLOWED_USERS")
      reset_allowlist_memo!
    end

    test "the ENV token authenticates without OIDC" do
      call_with(@instance_token)

      assert_response :success
      assert_nil json.dig("error"), json.inspect
    end

    test "the ENV token still authenticates with OIDC on" do
      # It's explicit operator config and the only path for callers with no user
      # (cron, CI). Enabling OIDC must not silently ignore a set variable.
      with_oidc { call_with(@instance_token) }

      assert_response :success
      assert_nil json.dig("error"), json.inspect
    end

    test "the shared instance token authenticates without OIDC" do
      shared = Setting.instance.mcp_token!

      call_with(shared)

      assert_response :success
      assert_nil json.dig("error"), json.inspect
    end

    test "the shared instance token is refused once OIDC is on" do
      # Turning OIDC on retires the shared credential rather than leaving a
      # second, unattributed way in.
      shared = Setting.instance.mcp_token!

      with_oidc { call_with(shared) }

      assert_response :unauthorized
    end

    test "a per-user token authenticates with OIDC on" do
      token = McpToken.for("dev@example.com")

      with_oidc { call_with(token.token) }

      assert_response :success
      assert_nil json.dig("error"), json.inspect
    end

    test "a per-user token is refused when there is no OIDC" do
      # No OIDC means no users; a leftover row must not be a way in.
      token = McpToken.for("dev@example.com")

      call_with(token.token)

      assert_response :unauthorized
    end

    test "a per-user token stops working once its owner leaves the allowlist" do
      token = McpToken.for("dev@example.com")

      ENV["SPLAT_ALLOWED_USERS"] = "someone-else@example.com"
      reset_allowlist_memo!

      with_oidc { call_with(token.token) }

      assert_response :unauthorized
      assert_equal(-32001, json.dig("error", "code"))
    end

    test "an expired per-user token is refused with an actionable renewal message" do
      token = McpToken.for("dev@example.com")
      Setting.instance.update_column(:mcp_token_ttl_days, 7)
      token.update_column(:last_authenticated_at, 8.days.ago)

      with_oidc { call_with(token.token) }

      assert_response :unauthorized
      message = json.dig("error", "message")
      # The client surfaces this to the human — it must say what to do and where.
      assert_match(/expired/i, message)
      assert_match(%r{/settings}, message)
    end

    test "an off-allowlist token is refused without leaking specifics" do
      token = McpToken.for("dev@example.com")
      ENV["SPLAT_ALLOWED_USERS"] = "someone-else@example.com"
      reset_allowlist_memo!

      with_oidc { call_with(token.token) }

      assert_no_match(/expired/i, json.dig("error", "message"))
    end

    test "an empty bearer is refused when no instance token has been minted" do
      # Setting.mcp_token is nil until the panel is opened; a blank stored token
      # must never compare equal to a blank presented one.
      assert_nil Setting.instance.mcp_token
      ENV.delete("MCP_AUTH_TOKEN")

      call_with("")

      assert_response :unauthorized
    end

    test "an unknown token is rejected" do
      call_with("bogus-#{SecureRandom.hex(8)}")

      assert_response :unauthorized
    end

    test "a missing token is rejected" do
      post "/mcp", params: rpc_body, headers: {"Content-Type" => "application/json"}

      assert_response :unauthorized
    end

    test "a blank MCP_AUTH_TOKEN does not let an empty bearer through" do
      # Guards the "unset env == open endpoint" failure mode.
      ENV["MCP_AUTH_TOKEN"] = ""

      call_with("")

      assert_response :unauthorized
    end

    private

    def rpc_body
      {jsonrpc: "2.0", id: 1, method: "tools/list", params: {}}.to_json
    end

    def call_with(token)
      post "/mcp", params: rpc_body, headers: {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{token}"
      }
    end

    def json
      JSON.parse(response.body)
    end

    def reset_allowlist_memo!
      SplatAuthorization.instance_variable_set(:@allowed_emails, nil)
      SplatAuthorization.instance_variable_set(:@allowed_domains, nil)
    end

    # oidc_configured? reads ENV every call, so stubbing it is enough — no memo.
    def with_oidc(&block)
      with_stub(SplatAuthorization, :oidc_configured?, -> { true }, &block)
    end
  end
end

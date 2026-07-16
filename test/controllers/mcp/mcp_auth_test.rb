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

    test "the ENV instance token still authenticates" do
      # Existing clients (cron, CI, an instance with no OIDC) were configured
      # with this and must keep working.
      call_with(@instance_token)

      assert_response :success
      assert_nil json.dig("error"), json.inspect
    end

    test "a per-user token authenticates" do
      token = McpToken.for("dev@example.com")

      call_with(token.token)

      assert_response :success
      assert_nil json.dig("error"), json.inspect
    end

    test "a per-user token stops working once its owner leaves the allowlist" do
      token = McpToken.for("dev@example.com")

      ENV["SPLAT_ALLOWED_USERS"] = "someone-else@example.com"
      reset_allowlist_memo!

      call_with(token.token)

      assert_response :unauthorized
      assert_equal(-32001, json.dig("error", "code"))
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
  end
end

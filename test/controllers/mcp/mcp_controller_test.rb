# frozen_string_literal: true

require "test_helper"

module Mcp
  class McpControllerTest < ActionDispatch::IntegrationTest
    setup do
      @token = "test-mcp-token-#{SecureRandom.hex(8)}"
      ENV["MCP_AUTH_TOKEN"] = @token
    end

    teardown do
      ENV.delete("MCP_AUTH_TOKEN")
    end

    test "search_slow_transactions passes valid tags hash through to DuckLake" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", { "tags" => { "user_id" => "123", "feature" => "x" } })
        assert_response :success
        assert_equal({ "user_id" => "123", "feature" => "x" }, captured[:kwargs][:tags])
      end
    end

    test "search_slow_transactions with no tags passes nil through" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {})
        assert_response :success
        assert_nil captured[:kwargs][:tags]
      end
    end

    test "search_slow_transactions rejects invalid tag key without hitting DuckLake" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", { "tags" => { "bad key" => "x" } })
        assert_response :success
        refute captured[:called], "DuckLake::Transaction.slow should not be called for invalid tag keys"
        body = JSON.parse(response.body)
        text = body.dig("result", "content", 0, "text").to_s
        assert_match(/Invalid tag key/, text)
      end
    end

    test "search_slow_transactions coerces non-string tag values to strings" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", { "tags" => { "user_id" => 42 } })
        assert_response :success
        assert_equal({ "user_id" => "42" }, captured[:kwargs][:tags])
      end
    end

    test "search_slow_transactions ignores empty tags hash" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", { "tags" => {} })
        assert_response :success
        assert_nil captured[:kwargs][:tags]
      end
    end

    private

    def call_tool(name, arguments)
      post "/mcp",
           params: {
             jsonrpc: "2.0",
             id: 1,
             method: "tools/call",
             params: { name: name, arguments: arguments }
           }.to_json,
           headers: {
             "Content-Type" => "application/json",
             "Authorization" => "Bearer #{@token}"
           }
    end

    # Swap DuckLake::Transaction.slow for a recording stub for the block.
    # Captured hash exposes { called:, kwargs: } so tests can assert on inputs.
    def with_slow_stub
      captured = { called: false, kwargs: nil }
      klass = DuckLake::Transaction.singleton_class
      original = DuckLake::Transaction.method(:slow)
      klass.send(:define_method, :slow) do |**kwargs|
        captured[:called] = true
        captured[:kwargs] = kwargs
        []
      end
      yield captured
    ensure
      klass.send(:define_method, :slow, original)
    end
  end
end

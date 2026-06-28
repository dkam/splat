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

    test "search_slow_transactions passes valid tags hash through to Transaction.slow" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {"user_id" => "123", "feature" => "x"}})
        assert_response :success
        assert_equal({"user_id" => "123", "feature" => "x"}, captured[:kwargs][:tags])
      end
    end

    test "search_slow_transactions with no tags passes nil through" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {})
        assert_response :success
        assert_nil captured[:kwargs][:tags]
      end
    end

    test "search_slow_transactions rejects invalid tag key without hitting Transaction.slow" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {"bad key" => "x"}})
        assert_response :success
        refute captured[:called], "Transaction.slow should not be called for invalid tag keys"
        body = JSON.parse(response.body)
        text = body.dig("result", "content", 0, "text").to_s
        assert_match(/Invalid tag key/, text)
      end
    end

    test "search_slow_transactions coerces non-string tag values to strings" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {"user_id" => 42}})
        assert_response :success
        assert_equal({"user_id" => "42"}, captured[:kwargs][:tags])
      end
    end

    test "search_slow_transactions ignores empty tags hash" do
      with_slow_stub do |captured|
        call_tool("search_slow_transactions", {"tags" => {}})
        assert_response :success
        assert_nil captured[:kwargs][:tags]
      end
    end

    test "get_issue_events does not crash when an event payload is nil" do
      # Old events can have payload purged by retention while the event row stays.
      # format_issue_events used to dig into event.payload['environment'] and
      # raise 'undefined method [] for nil'. The fix reads denormalized columns.
      project = projects(:one)
      issue = Issue.create!(
        project: project,
        fingerprint: "purged-payload-test",
        title: "Test",
        first_seen: 2.weeks.ago,
        last_seen: 2.weeks.ago
      )
      Event.create!(
        project: project,
        issue: issue,
        event_id: SecureRandom.uuid,
        timestamp: 2.weeks.ago,
        environment: "production",
        server_name: "test-host",
        payload: nil
      )

      call_tool("get_issue_events", {"issue_id" => issue.id})
      assert_response :success
      body = JSON.parse(response.body)
      text = body.dig("result", "content", 0, "text").to_s
      assert_match(/Environment:.*production/, text)
      assert_match(/Server:.*test-host/, text)
    end

    private

    test "search_logs returns matching logs" do
      project = projects(:one)
      Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
        level: :error, source: "sentry", body: "mcp searchable log", trace_id: "mcp-trace", payload: {})

      call_tool("search_logs", {"query" => "mcp searchable", "level" => "error"})
      assert_response :success
      assert_match "mcp searchable log", tool_text
    end

    test "get_log returns a record by log_id" do
      project = projects(:one)
      id = SecureRandom.uuid_v7
      Log.create!(project_id: project.id, log_id: id, timestamp: Time.current,
        level: :info, source: "sentry", body: "fetch me",
        payload: {"attributes" => {"sentry.environment" => "production"}})

      call_tool("get_log", {"log_id" => id})
      assert_response :success
      assert_match "fetch me", tool_text
      assert_match "Attributes", tool_text
    end

    test "get_trace_logs collects logs for a trace" do
      project = projects(:one)
      2.times do |i|
        Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: i.minutes.ago,
          level: :info, source: "sentry", body: "trace line #{i}", trace_id: "shared-trace", payload: {})
      end

      call_tool("get_trace_logs", {"trace_id" => "shared-trace"})
      assert_response :success
      assert_match "trace line 0", tool_text
      assert_match "trace line 1", tool_text
    end

    test "get_transaction surfaces the promoted trace_id so logs can be cross-referenced" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "ProductsController#show", duration: 120,
        trace_id: "txn-trace-xyz")

      call_tool("get_transaction", {"transaction_id" => txn.id})
      assert_response :success
      assert_match "txn-trace-xyz", tool_text
      assert_match "get_trace_logs", tool_text
    end

    test "get_transaction_spans renders the waterfall from the span_tree blob" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "ProductsController#show", duration: 120)
      t0 = Time.current
      tree = {"trace_id" => "tr", "spans" => [
        {"span_id" => "s1", "parent_span_id" => nil, "op" => "db.sql.active_record", "status" => "ok",
         "description" => "SELECT * FROM products", "ts" => t0, "end_ts" => t0 + 0.03,
         "depth" => 0, "sequence" => 0, "tags" => {}, "data" => {}}
      ]}
      SpanTree.create_from_tree!(project_id: project.id, transaction_id: txn.transaction_id,
        timestamp: txn.timestamp, tree: tree, span_count: 1, spans_truncated: false)

      call_tool("get_transaction_spans", {"transaction_id" => txn.id})
      assert_response :success
      assert_match "db.sql.active_record", tool_text
      assert_match "SELECT * FROM products", tool_text
    end

    test "get_transaction_spans falls back to legacy span rows during the dual-read window" do
      project = projects(:one)
      txn = Transaction.create!(project: project, transaction_id: SecureRandom.uuid,
        timestamp: Time.current, transaction_name: "ProductsController#show", duration: 120)
      t0 = Time.current
      Span.create!(project_id: project.id, transaction_id: txn.transaction_id,
        span_id: "s1", op: "http.client", description: "GET https://api.example",
        timestamp: t0, end_timestamp: t0 + 0.04, depth: 0, sequence: 0)

      call_tool("get_transaction_spans", {"transaction_id" => txn.id})
      assert_response :success
      assert_match "http.client", tool_text
      assert_match "GET https://api.example", tool_text
    end

    def tool_text
      JSON.parse(response.body).dig("result", "content", 0, "text").to_s
    end

    def call_tool(name, arguments)
      post "/mcp",
        params: {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {name: name, arguments: arguments}
        }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{@token}"
        }
    end

    # Swap Transaction.slow for a recording stub for the block.
    # Captured hash exposes { called:, kwargs: } so tests can assert on inputs.
    def with_slow_stub
      captured = {called: false, kwargs: nil}
      klass = Transaction.singleton_class
      original = Transaction.method(:slow)
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

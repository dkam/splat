# frozen_string_literal: true

require "test_helper"

class SplatMcpServerTest < ActiveSupport::TestCase
  SLOW = "WITH RECURSIVE r(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM r LIMIT 20000000) SELECT count(*) FROM r"

  teardown { ENV.delete("SPLAT_MCP_STATEMENT_TIMEOUT") }

  # The 2026-09-12 incident: one wide search_logs held a Puma thread — and,
  # through the GVL, the whole process — for ~20 minutes.
  test "a tool whose query runs too long comes back as a tool error saying to narrow it" do
    skip "sqlite3 #{SQLite3::VERSION}: statement_timeout is broken (sparklemotion/sqlite3-ruby#737)" unless SqliteStatementTimeout.supported?

    ENV["SPLAT_MCP_STATEMENT_TIMEOUT"] = "0.2"
    tools = SplatMcpTools.new
    tools.define_singleton_method(:search_logs) do |_args|
      LogsRecord.lease_connection.select_value(SLOW)
      render_text("finished")
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = SplatMcpServer.dispatch(tools, "search_logs", {})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert response.error?, "expected a tool error, got: #{response.content.inspect}"
    assert_match(/narrow/i, response.content.first[:text])
    assert_operator elapsed, :<, 1.5, "ran #{elapsed.round(2)}s under a 200ms cap"
  end

  test "the timeout defaults to 15 seconds" do
    assert_equal 15_000, SplatMcpServer.statement_timeout_ms
    ENV["SPLAT_MCP_STATEMENT_TIMEOUT"] = "30"
    assert_equal 30_000, SplatMcpServer.statement_timeout_ms
  end
end

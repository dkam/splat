# frozen_string_literal: true

require "test_helper"

class SqliteStatementTimeoutTest < ActiveSupport::TestCase
  # ~20M rows: a couple of seconds uncapped, so a 200ms cap visibly stops it.
  SLOW = "WITH RECURSIVE r(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM r LIMIT 20000000) SELECT count(*) FROM r"
  # ~2M rows: a few hundred ms, comfortably more than the 200ms cap.
  PAST_CAP = "WITH RECURSIVE r(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM r LIMIT 2000000) SELECT count(*) FROM r"
  QUICK = "WITH RECURSIVE r(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM r LIMIT 100000) SELECT count(*) FROM r"

  test "a statement past the timeout is stopped, on every database" do
    skip_unless_supported

    SqliteStatementTimeout.records.each do |record|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = assert_raises(ActiveRecord::StatementInvalid, record.name) do
        SqliteStatementTimeout.with(200) { record.lease_connection.select_value(SLOW) }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert SqliteStatementTimeout.interrupted?(error), "#{record.name}: #{error.class}: #{error.message}"
      assert_operator elapsed, :<, 1.5, "#{record.name} ran #{elapsed.round(2)}s under a 200ms cap"
    end
  end

  # Connections go back to the pool and serve the UI and the workers next,
  # where retention and the rollups legitimately run for minutes.
  test "the connection has no timeout after the block" do
    skip_unless_supported

    record = LogsRecord
    assert_raises(ActiveRecord::StatementInvalid) do
      SqliteStatementTimeout.with(200) { record.lease_connection.select_value(SLOW) }
    end

    assert_equal 2_000_000, record.lease_connection.select_value(PAST_CAP)
  end

  # Holds on any gem: on a broken one `with` must not switch the timeout on,
  # or every MCP query would fail.
  test "a statement inside the timeout finishes" do
    assert_equal 100_000, SqliteStatementTimeout.with(10_000) { LogsRecord.lease_connection.select_value(QUICK) }
  end

  private

  def skip_unless_supported
    skip "sqlite3 #{SQLite3::VERSION}: statement_timeout is broken (sparklemotion/sqlite3-ruby#737)" unless SqliteStatementTimeout.supported?
  end
end

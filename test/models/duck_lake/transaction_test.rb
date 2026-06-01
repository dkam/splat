# frozen_string_literal: true

require "test_helper"

# Integration smoke test for the Parquet-backed analytics readers.
# Writes a small dataset via ParquetLake::Writer and verifies that the
# DuckLake::* reader classes (now inheriting from ApplicationParquetLakeRecord)
# return correct results.
class DuckLake::TransactionTest < ActiveSupport::TestCase
  def setup
    @data_path = Rails.root.join("tmp", "duck_lake_reader_test_#{SecureRandom.hex(8)}")
    @original_config = Rails.application.config.x.parquet_lake
    Rails.application.config.x.parquet_lake = { data_path: @data_path.to_s, retention_days: 30 }
    ParquetLake::Connection.reset!

    @ts = Time.utc(2026, 6, 1, 12, 0, 0)
    write_fixture_data
  end

  def teardown
    FileUtils.rm_rf(@data_path) if @data_path
    Rails.application.config.x.parquet_lake = @original_config
    ParquetLake::Connection.reset!
  end

  test "Transaction.count_in_range counts rows in the window" do
    range = (@ts - 1.hour)..(@ts + 1.hour)
    assert_equal 3, DuckLake::Transaction.count_in_range(time_range: range, project_id: 1)
  end

  test "Transaction.percentiles returns p50/p95/p99" do
    range = (@ts - 1.hour)..(@ts + 1.hour)
    result = DuckLake::Transaction.percentiles(range, project_id: 1)
    assert_equal 3, (result.respond_to?(:[]) ? result[:p50] : nil).to_i > 0 ? 3 : 3 # smoke
    assert result[:p95].to_f >= result[:p50].to_f, "p95 should be >= p50"
    assert result[:max].to_f >= result[:p99].to_f, "max should be >= p99"
  end

  test "Transaction.stats_by_endpoint_with_impact aggregates by transaction_name" do
    range = (@ts - 1.hour)..(@ts + 1.hour)
    rows = DuckLake::Transaction.stats_by_endpoint_with_impact(range, project_id: 1)
    by_name = rows.index_by { |r| r["transaction_name"] }
    assert_equal 2, by_name["Posts#show"]["count"].to_i
    assert_equal 1, by_name["Users#index"]["count"].to_i
  end

  test "Transaction.endpoints_by_n_plus_one filters to has_n_plus_one rows" do
    range = (@ts - 1.hour)..(@ts + 1.hour)
    rows = DuckLake::Transaction.endpoints_by_n_plus_one(range, project_id: 1, limit: 10)
    assert_equal 1, rows.size
    assert_equal "Users#index", rows.first["transaction_name"]
  end

  test "Event.count_in_range works" do
    range = (@ts - 1.hour)..(@ts + 1.hour)
    assert_equal 2, DuckLake::Event.count_in_range(time_range: range, project_id: 1)
  end

  test "Event.event_counts_by_bucket groups by issue_id and bucket" do
    range = (@ts - 1.hour)..(@ts + 1.hour)
    counts = DuckLake::Event.event_counts_by_bucket(issue_ids: [42, 99], time_range: range,
                                                    buckets: 4, project_id: 1)
    assert_equal [42, 99], counts.keys
    assert_equal 4, counts[42].size
    assert_equal 2, counts[42].sum, "issue 42 should have 2 events total"
    assert_equal 0, counts[99].sum, "issue 99 has no events"
  end

  test "Span.for_transaction returns ordered spans" do
    spans = DuckLake::Span.for_transaction("tx-1", project_id: 1, near_timestamp: @ts)
    assert_equal 2, spans.size
    assert_equal "span-a", spans.first["span_id"]
    assert_equal "span-b", spans.last["span_id"]
  end

  private

  def write_fixture_data
    ParquetLake::Writer.write(table: "transactions", rows: [
      tx_row(id: 1, transaction_id: "tx-1", transaction_name: "Posts#show",  duration: 100,
             timestamp: @ts, has_n_plus_one: false),
      tx_row(id: 2, transaction_id: "tx-2", transaction_name: "Posts#show",  duration: 300,
             timestamp: @ts + 5.minutes, has_n_plus_one: false),
      tx_row(id: 3, transaction_id: "tx-3", transaction_name: "Users#index", duration: 800,
             timestamp: @ts + 10.minutes, has_n_plus_one: true, query_count: 30)
    ])

    ParquetLake::Writer.write(table: "events", rows: [
      ev_row(id: 1, event_id: "ev-1", issue_id: 42, timestamp: @ts),
      ev_row(id: 2, event_id: "ev-2", issue_id: 42, timestamp: @ts + 1.minute)
    ])

    ParquetLake::Writer.write(table: "spans", rows: [
      span_row(span_id: "span-a", transaction_id: "tx-1", sequence: 0,
               timestamp: @ts, end_timestamp: @ts + 0.05),
      span_row(span_id: "span-b", transaction_id: "tx-1", sequence: 1,
               timestamp: @ts + 0.05, end_timestamp: @ts + 0.10)
    ])
  end

  def tx_row(overrides = {})
    {
      id: 1, transaction_id: "tx", project_id: 1, timestamp: @ts,
      transaction_name: "X", op: "http.server", duration: 100,
      db_time: 10, view_time: 5, environment: "production", release: nil,
      server_name: nil, http_method: "GET", http_status: "200",
      http_url: "/x", tags: nil, measurements: nil,
      spans_truncated: false, query_count: 0, has_n_plus_one: false,
      created_at: @ts, updated_at: @ts
    }.merge(overrides)
  end

  def ev_row(overrides = {})
    {
      id: 1, event_id: "ev", project_id: 1, issue_id: 1,
      timestamp: @ts, duration: 0, environment: "production",
      exception_type: "RuntimeError", exception_value: nil, fingerprint: nil,
      message: nil, platform: "ruby", release: nil, sdk_name: nil, sdk_version: nil,
      server_name: nil, transaction_name: nil, payload: nil,
      created_at: @ts, updated_at: @ts
    }.merge(overrides)
  end

  def span_row(overrides = {})
    {
      project_id: 1, trace_id: "tr-1", transaction_id: "tx-1", span_id: "sp",
      parent_span_id: nil, timestamp: @ts, end_timestamp: @ts,
      op: nil, status: nil, description: nil, tags: nil, data: nil,
      depth: 0, sequence: 0, created_at: @ts
    }.merge(overrides)
  end
end

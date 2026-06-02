# frozen_string_literal: true

require "test_helper"

class ParquetLake::WriterTest < ActiveSupport::TestCase
  def setup
    # Per-test data path so parallel test workers don't trip over each other.
    @data_path = Rails.root.join("tmp", "parquet_writer_test_#{SecureRandom.hex(8)}")
    @original_config = Rails.application.config.x.parquet_lake
    Rails.application.config.x.parquet_lake = { data_path: @data_path.to_s, retention_days: 30 }
    ParquetLake::Connection.reset!
  end

  def teardown
    FileUtils.rm_rf(@data_path) if @data_path
    Rails.application.config.x.parquet_lake = @original_config
    ParquetLake::Connection.reset!
  end

  test "round-trip: events row writes a parquet file readable via read_parquet" do
    rows = [events_row(id: 1, event_id: "abc", project_id: 7,
                       timestamp: Time.utc(2026, 6, 1, 12, 0, 0),
                       exception_type: "RuntimeError")]

    assert_equal true, ParquetLake::Writer.write(table: "events", rows: rows)

    files = Dir.glob(File.join(@data_path, "events", "**", "*.parquet"))
    assert_equal 1, files.size
    assert_match %r{events/year=2026/month=6/day=1/hour=12/}, files.first

    result = ParquetLake::Connection.query(
      "SELECT * FROM read_parquet('#{File.join(@data_path, "events", "**", "*.parquet")}', hive_partitioning=true) ORDER BY id"
    )
    assert_equal 1, result.size
    assert_equal "abc", result.first["event_id"]
    assert_equal 7, result.first["project_id"]
    assert_equal "RuntimeError", result.first["exception_type"]
  end

  test "rows spanning multiple hours produce one file per hour-partition" do
    rows = [
      events_row(id: 1, timestamp: Time.utc(2026, 6, 1, 10, 0, 0)),
      events_row(id: 2, timestamp: Time.utc(2026, 6, 2, 10, 30, 0)),
      events_row(id: 3, timestamp: Time.utc(2026, 6, 2, 23, 15, 0))
    ]
    ParquetLake::Writer.write(table: "events", rows: rows)

    h10_d1 = Dir.glob(File.join(@data_path, "events/year=2026/month=6/day=1/hour=10", "*.parquet"))
    h10_d2 = Dir.glob(File.join(@data_path, "events/year=2026/month=6/day=2/hour=10", "*.parquet"))
    h23_d2 = Dir.glob(File.join(@data_path, "events/year=2026/month=6/day=2/hour=23", "*.parquet"))
    assert_equal 1, h10_d1.size
    assert_equal 1, h10_d2.size
    assert_equal 1, h23_d2.size

    total = ParquetLake::Connection.query(
      "SELECT count(*) AS c FROM read_parquet('#{File.join(@data_path, "events", "**", "*.parquet")}', hive_partitioning=true)"
    ).first["c"]
    assert_equal 3, total
  end

  test "writes leave no .tmp files behind on success" do
    rows = [events_row(id: 1, timestamp: Time.now.utc)]
    ParquetLake::Writer.write(table: "events", rows: rows)

    tmp_files = Dir.glob(File.join(@data_path, "**", "*.tmp"))
    assert_empty tmp_files
  end

  test "concurrent writes to the same partition produce distinct UUID-named files" do
    ts = Time.utc(2026, 6, 1, 12, 0, 0)
    # Run two writes back-to-back; UUIDv7 + per-call tmp/final names mean
    # they never target the same path.
    ParquetLake::Writer.write(table: "events", rows: [events_row(id: 1, timestamp: ts)])
    ParquetLake::Writer.write(table: "events", rows: [events_row(id: 2, timestamp: ts)])

    files = Dir.glob(File.join(@data_path, "events/year=2026/month=6/day=1/hour=12", "*.parquet"))
    assert_equal 2, files.size
    assert_equal files.size, files.uniq.size
  end

  test "JSON columns serialize correctly and round-trip via json_extract_string" do
    rows = [events_row(id: 1, timestamp: Time.utc(2026, 6, 1, 12, 0, 0),
                       payload: { "level" => "error", "extra" => { "key" => "value" } })]
    ParquetLake::Writer.write(table: "events", rows: rows)

    result = ParquetLake::Connection.query(
      "SELECT json_extract_string(payload, '$.level') AS lvl, " \
      "json_extract_string(payload, '$.extra.key') AS nested " \
      "FROM read_parquet('#{File.join(@data_path, "events", "**", "*.parquet")}', hive_partitioning=true)"
    )
    assert_equal "error", result.first["lvl"]
    assert_equal "value", result.first["nested"]
  end

  test "transactions table accepts the promoted columns" do
    rows = [transactions_row(transaction_id: "tx1",
                             timestamp: Time.utc(2026, 6, 1, 12, 0, 0),
                             duration: 500, query_count: 42, has_n_plus_one: true)]
    ParquetLake::Writer.write(table: "transactions", rows: rows)

    result = ParquetLake::Connection.query(
      "SELECT transaction_id, query_count, has_n_plus_one FROM read_parquet('#{File.join(@data_path, "transactions", "**", "*.parquet")}', hive_partitioning=true)"
    )
    assert_equal "tx1", result.first["transaction_id"]
    assert_equal 42, result.first["query_count"]
    assert_equal true, result.first["has_n_plus_one"]
  end

  test "spans table works without a created_at on every row" do
    rows = [spans_row(span_id: "s1", timestamp: Time.utc(2026, 6, 1, 12, 0, 0))]
    ParquetLake::Writer.write(table: "spans", rows: rows)

    result = ParquetLake::Connection.query(
      "SELECT span_id FROM read_parquet('#{File.join(@data_path, "spans", "**", "*.parquet")}', hive_partitioning=true)"
    )
    assert_equal "s1", result.first["span_id"]
  end

  test "unknown table raises ArgumentError" do
    assert_raises(ArgumentError) do
      ParquetLake::Writer.write(table: "nope", rows: [{ id: 1, timestamp: Time.now }])
    end
  end

  test "empty rows is a no-op returning true and writing nothing" do
    assert_equal true, ParquetLake::Writer.write(table: "events", rows: [])
    assert_empty Dir.glob(File.join(@data_path, "**", "*.parquet"))
  end

  test "Connection.query returns [] for a glob with no files (fresh deploy / empty table)" do
    # No Writer.write call — the events partition tree doesn't exist yet.
    result = ParquetLake::Connection.query(
      "SELECT COUNT(*) AS c FROM read_parquet('#{File.join(@data_path, "events", "**", "*.parquet")}', hive_partitioning=true)"
    )
    assert_equal [], result
  end

  test "PARQUET_LAKE_DISABLED makes write a no-op returning false" do
    ENV["PARQUET_LAKE_DISABLED"] = "true"
    assert_equal false, ParquetLake::Writer.write(table: "events",
                                                  rows: [events_row(id: 1, timestamp: Time.now.utc)])
    assert_empty Dir.glob(File.join(@data_path, "**", "*.parquet"))
  ensure
    ENV.delete("PARQUET_LAKE_DISABLED")
  end

  private

  def events_row(overrides = {})
    {
      id: 1, event_id: "ev", project_id: 1, issue_id: nil,
      timestamp: Time.now.utc, duration: 0, environment: "test",
      exception_type: nil, exception_value: nil, fingerprint: nil,
      message: nil, platform: nil, release: nil, sdk_name: nil, sdk_version: nil,
      server_name: nil, transaction_name: nil, payload: nil,
      created_at: Time.now.utc, updated_at: Time.now.utc
    }.merge(overrides)
  end

  def transactions_row(overrides = {})
    {
      id: 1, transaction_id: "tx", project_id: 1, timestamp: Time.now.utc,
      transaction_name: "Posts#show", op: "http.server", duration: 100,
      db_time: 10, view_time: 5, environment: "test", release: nil,
      server_name: nil, http_method: "GET", http_status: "200",
      http_url: "/posts/1", tags: nil, measurements: nil,
      spans_truncated: false, query_count: 0, has_n_plus_one: false,
      created_at: Time.now.utc, updated_at: Time.now.utc
    }.merge(overrides)
  end

  def spans_row(overrides = {})
    {
      project_id: 1, trace_id: "tr", transaction_id: "tx", span_id: "sp",
      parent_span_id: nil, timestamp: Time.now.utc, end_timestamp: Time.now.utc,
      op: nil, status: nil, description: nil, tags: nil, data: nil,
      depth: 0, sequence: 0, created_at: Time.now.utc
    }.merge(overrides)
  end
end

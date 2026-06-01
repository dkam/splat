# frozen_string_literal: true

require "test_helper"

class ParquetLake::CompactionJobTest < ActiveSupport::TestCase
  def setup
    @data_path = Rails.root.join("tmp", "parquet_compaction_test_#{SecureRandom.hex(8)}")
    @original_config = Rails.application.config.x.parquet_lake
    Rails.application.config.x.parquet_lake = { data_path: @data_path.to_s, retention_days: 30 }
    ParquetLake::Connection.reset!
  end

  def teardown
    FileUtils.rm_rf(@data_path) if @data_path
    Rails.application.config.x.parquet_lake = @original_config
    ParquetLake::Connection.reset!
  end

  test "merges multiple parquet files in an old partition into one" do
    yesterday = Date.current - 1
    # Two separate Writer.write calls land as two files in the same day-partition.
    ParquetLake::Writer.write(table: "transactions", rows: [tx_row(transaction_id: "a", timestamp: yesterday.to_time(:utc) + 1.hour)])
    ParquetLake::Writer.write(table: "transactions", rows: [tx_row(transaction_id: "b", timestamp: yesterday.to_time(:utc) + 2.hours)])

    partition_dir = File.join(@data_path, "transactions",
                              "year=#{yesterday.year}", "month=#{yesterday.month}", "day=#{yesterday.day}")
    assert_equal 2, Dir.glob(File.join(partition_dir, "*.parquet")).size

    compacted = ParquetLake::CompactionJob.new.perform
    assert_equal 1, compacted

    files = Dir.glob(File.join(partition_dir, "*.parquet"))
    assert_equal 1, files.size, "expected exactly one merged file"

    # All rows preserved
    result = ParquetLake::Connection.query(
      "SELECT count(*) AS c, sum(CASE WHEN transaction_id='a' THEN 1 ELSE 0 END) AS a_n " \
      "FROM read_parquet('#{files.first}')"
    ).first
    assert_equal 2, result["c"]
    assert_equal 1, result["a_n"]
  end

  test "skips today's partition (still being written)" do
    today = Date.current
    ParquetLake::Writer.write(table: "transactions", rows: [tx_row(transaction_id: "a", timestamp: today.to_time(:utc) + 1.hour)])
    ParquetLake::Writer.write(table: "transactions", rows: [tx_row(transaction_id: "b", timestamp: today.to_time(:utc) + 2.hours)])

    partition_dir = File.join(@data_path, "transactions",
                              "year=#{today.year}", "month=#{today.month}", "day=#{today.day}")
    assert_equal 2, Dir.glob(File.join(partition_dir, "*.parquet")).size

    ParquetLake::CompactionJob.new.perform

    assert_equal 2, Dir.glob(File.join(partition_dir, "*.parquet")).size, "today's partition should be untouched"
  end

  test "single-file partition is a no-op" do
    yesterday = Date.current - 1
    ParquetLake::Writer.write(table: "transactions", rows: [tx_row(transaction_id: "a", timestamp: yesterday.to_time(:utc) + 1.hour)])

    partition_dir = File.join(@data_path, "transactions",
                              "year=#{yesterday.year}", "month=#{yesterday.month}", "day=#{yesterday.day}")
    files_before = Dir.glob(File.join(partition_dir, "*.parquet"))
    assert_equal 1, files_before.size

    compacted = ParquetLake::CompactionJob.new.perform
    assert_equal 0, compacted

    files_after = Dir.glob(File.join(partition_dir, "*.parquet"))
    assert_equal files_before, files_after
  end

  test "no .tmp files remain after a successful compaction" do
    yesterday = Date.current - 1
    2.times do |i|
      ParquetLake::Writer.write(table: "transactions",
                                rows: [tx_row(transaction_id: "tx#{i}", timestamp: yesterday.to_time(:utc) + i.hours)])
    end

    ParquetLake::CompactionJob.new.perform

    tmp_files = Dir.glob(File.join(@data_path, "**", "*.tmp"))
    assert_empty tmp_files
  end

  private

  def tx_row(overrides = {})
    {
      id: 1, transaction_id: "tx", project_id: 1, timestamp: Time.now.utc,
      transaction_name: "X#show", op: "http.server", duration: 100,
      db_time: 10, view_time: 5, environment: "production", release: nil,
      server_name: nil, http_method: "GET", http_status: "200",
      http_url: "/x", tags: nil, measurements: nil,
      spans_truncated: false, query_count: 0, has_n_plus_one: false,
      created_at: Time.now.utc, updated_at: Time.now.utc
    }.merge(overrides)
  end
end

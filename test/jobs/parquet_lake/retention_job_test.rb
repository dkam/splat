# frozen_string_literal: true

require "test_helper"

class ParquetLake::RetentionJobTest < ActiveSupport::TestCase
  def setup
    @data_path = Rails.root.join("tmp", "parquet_retention_test_#{SecureRandom.hex(8)}")
    @original_config = Rails.application.config.x.parquet_lake
    Rails.application.config.x.parquet_lake = { data_path: @data_path.to_s, retention_days: 30 }
    ParquetLake::Connection.reset!
  end

  def teardown
    FileUtils.rm_rf(@data_path) if @data_path
    Rails.application.config.x.parquet_lake = @original_config
    ParquetLake::Connection.reset!
  end

  test "removes partition dirs older than retention_days" do
    old = Date.current - 40
    fresh = Date.current - 5

    ParquetLake::Writer.write(table: "events", rows: [ev_row(id: 1, timestamp: old.to_time(:utc) + 1.hour)])
    ParquetLake::Writer.write(table: "events", rows: [ev_row(id: 2, timestamp: fresh.to_time(:utc) + 1.hour)])

    old_dir = File.join(@data_path, "events", "year=#{old.year}", "month=#{old.month}", "day=#{old.day}")
    fresh_dir = File.join(@data_path, "events", "year=#{fresh.year}", "month=#{fresh.month}", "day=#{fresh.day}")
    assert File.directory?(old_dir)
    assert File.directory?(fresh_dir)

    removed = ParquetLake::RetentionJob.new.perform
    assert_equal 1, removed

    refute File.directory?(old_dir), "old partition should be gone"
    assert File.directory?(fresh_dir), "fresh partition should still exist"
  end

  test "removes empty year/month parent directories" do
    old = Date.current - 60
    ParquetLake::Writer.write(table: "events", rows: [ev_row(id: 1, timestamp: old.to_time(:utc))])

    year_dir = File.join(@data_path, "events", "year=#{old.year}")
    month_dir = File.join(year_dir, "month=#{old.month}")

    ParquetLake::RetentionJob.new.perform

    refute File.directory?(month_dir), "empty month dir should be removed"
    # year_dir is removed too if it has no remaining month children
    if !Dir.glob(File.join(year_dir, "month=*")).any?
      refute File.directory?(year_dir), "empty year dir should be removed"
    end
  end

  test "explicit retention_days arg overrides config" do
    fresh = Date.current - 5
    ParquetLake::Writer.write(table: "events", rows: [ev_row(id: 1, timestamp: fresh.to_time(:utc))])

    fresh_dir = File.join(@data_path, "events", "year=#{fresh.year}", "month=#{fresh.month}", "day=#{fresh.day}")
    assert File.directory?(fresh_dir)

    removed = ParquetLake::RetentionJob.new.perform(retention_days: 1)
    assert_equal 1, removed
    refute File.directory?(fresh_dir)
  end

  test "no partitions to remove is a successful no-op" do
    today = Date.current
    ParquetLake::Writer.write(table: "events", rows: [ev_row(id: 1, timestamp: today.to_time(:utc))])

    removed = ParquetLake::RetentionJob.new.perform
    assert_equal 0, removed
  end

  private

  def ev_row(overrides = {})
    {
      id: 1, event_id: "ev", project_id: 1, issue_id: 1,
      timestamp: Time.now.utc, duration: 0, environment: "production",
      exception_type: "RuntimeError", exception_value: nil, fingerprint: nil,
      message: nil, platform: "ruby", release: nil, sdk_name: nil, sdk_version: nil,
      server_name: nil, transaction_name: nil, payload: nil,
      created_at: Time.now.utc, updated_at: Time.now.utc
    }.merge(overrides)
  end
end

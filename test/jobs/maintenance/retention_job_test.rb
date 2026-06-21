require "test_helper"

class Maintenance::RetentionJobTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Perf", slug: "perf", public_key: "perf-key")
    Setting.instance.update!(transactions_data_retention_days: 90, histograms_retention_days: 540)
  end

  def insert_hourly_stat(hour_bucket:)
    Transaction.connection.exec_insert(
      Transaction.sanitize_sql_array([
        "INSERT INTO transaction_hourly_stats (project_id, transaction_name, environment, hour_bucket, count, sum_duration, max_duration) VALUES (?, ?, '', ?, 1, 100, 100)",
        @project.id, "GET /x", hour_bucket
      ]), "test insert"
    )
  end

  test "retires hourly_stats older than the histogram cutoff, keeps recent" do
    old_hour    = (Time.current - 600.days).beginning_of_hour
    recent_hour = (Time.current - 10.days).beginning_of_hour
    insert_hourly_stat(hour_bucket: old_hour)
    insert_hourly_stat(hour_bucket: recent_hour)

    Maintenance::RetentionJob.new.perform

    remaining = Transaction.connection.select_values(
      "SELECT hour_bucket FROM transaction_hourly_stats WHERE project_id = #{@project.id}"
    )
    assert_equal 1, remaining.size, "the 600-day-old row is purged, the 10-day-old one kept"
    kept = remaining.first.to_time(:utc)
    assert kept > (Time.current - 540.days), "surviving row is within the retention window"
  end

  test "raw transactions are deleted while their aggregate history is retained" do
    old = (Time.current - 200.days)
    # Created via the model so the live bump writes the long-lived aggregates.
    Transaction.create!(project: @project, transaction_id: SecureRandom.uuid,
                        transaction_name: "GET /x", timestamp: old, duration: 100)

    Maintenance::RetentionJob.new.perform

    assert_equal 0, Transaction.where(project_id: @project.id).count, "raw row past 90d cutoff is gone"
    surviving = Transaction.connection.select_value(
      "SELECT SUM(count) FROM transaction_hourly_stats WHERE project_id = #{@project.id}"
    ).to_i
    assert_equal 1, surviving, "aggregate history (within 540d) survives"
  end
end

require "test_helper"

class HistogramRollupJobTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Perf", slug: "perf", public_key: "perf-key")
    @hour = (Time.current - 3.hours).beginning_of_hour
  end

  # insert_all! skips the after_create live bump, so the aggregates only exist
  # if the rollup builds them — this isolates the rollup's own correctness.
  def insert_raw(rows)
    # insert_all! requires a uniform key set across rows, so spell out every
    # nullable column with a default.
    defaults = {
      project_id: @project.id, transaction_name: "GET /x", timestamp: @hour,
      duration: 100, db_time: nil, view_time: nil, http_status: nil,
      query_count: 0, has_n_plus_one: false, spans_truncated: false
    }
    Transaction.insert_all!(rows.map { |r|
      defaults.merge(r).merge(
        transaction_id: SecureRandom.uuid,
        created_at: Time.current, updated_at: Time.current
      )
    })
  end

  test "rollup builds histogram + hourly_stats from raw rows" do
    insert_raw([
      {duration: 100, db_time: 40, view_time: 10, query_count: 2, http_status: "200"},
      {duration: 100, db_time: 60, query_count: 4, http_status: "200"},
      {duration: 1000, has_n_plus_one: true, query_count: 30, http_status: "500"}
    ])

    Analytics::HistogramRollupJob.new.perform(@hour)

    row = Transaction.connection.select_one(
      "SELECT * FROM transaction_hourly_stats WHERE project_id = #{@project.id}"
    )
    assert_equal 3, row["count"]
    assert_equal 1200, row["sum_duration"]
    assert_equal 100, row["min_duration"]
    assert_equal 1000, row["max_duration"]
    assert_equal 100, row["sum_db_time"]   # 40 + 60 (third row null)
    assert_equal 2, row["db_time_count"]
    assert_equal 1, row["view_time_count"]
    assert_equal 36, row["sum_query_count"]
    assert_equal 30, row["max_query_count"]
    assert_equal 1, row["n_plus_one_count"]
    assert_equal 1, row["error_count"]

    hist = Transaction.connection.select_value(
      "SELECT SUM(count) FROM transaction_histograms WHERE project_id = #{@project.id}"
    )
    assert_equal 3, hist
  end

  test "rollup is idempotent — re-running overwrites, never doubles" do
    insert_raw([{duration: 100}, {duration: 200}])
    job = Analytics::HistogramRollupJob.new
    job.perform(@hour)
    job.perform(@hour)

    row = Transaction.connection.select_one(
      "SELECT count, sum_duration FROM transaction_hourly_stats WHERE project_id = #{@project.id}"
    )
    assert_equal 2, row["count"]
    assert_equal 300, row["sum_duration"]

    hist = Transaction.connection.select_value(
      "SELECT SUM(count) FROM transaction_histograms WHERE project_id = #{@project.id}"
    )
    assert_equal 2, hist
  end

  test "rollup corrects drift from the live bump for the same hour" do
    # Live-bumped row (via after_create) then a late raw insert the bump missed.
    Transaction.create!(project: @project, transaction_id: SecureRandom.uuid,
      transaction_name: "GET /x", timestamp: @hour, duration: 100)
    insert_raw([{duration: 100}, {duration: 100}]) # +2 rows the live bump never saw

    Analytics::HistogramRollupJob.new.perform(@hour)

    row = Transaction.connection.select_one(
      "SELECT count FROM transaction_hourly_stats WHERE project_id = #{@project.id}"
    )
    assert_equal 3, row["count"], "rollup recount should reflect all raw rows for the hour"
  end
end

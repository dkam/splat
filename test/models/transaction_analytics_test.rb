require "test_helper"

# Covers the aggregate-backed read paths: every windowed stat is served from
# transaction_hourly_stats (scalars) + transaction_histograms (percentiles),
# kept fresh by the after_create live bump. The headline property is that these
# survive deletion of the raw transactions.
class TransactionAnalyticsTest < ActiveSupport::TestCase
  def setup
    @project = Project.create!(name: "Perf", slug: "perf", public_key: "perf-key")
    # Timestamp into a completed past hour so the percentile reader serves it
    # from the histogram (its current-hour arm reads raw); this lets the
    # deletion-survival assertions exercise the aggregate path.
    @hour = (Time.current - 2.hours).beginning_of_hour
    @range = (Time.current - 24.hours)..Time.current
  end

  def create_txn(name: "GET /x", duration:, at: @hour, **attrs)
    Transaction.create!(
      project: @project, transaction_id: SecureRandom.uuid,
      transaction_name: name, timestamp: at, duration: duration, **attrs
    )
  end

  def hourly_row(name: "GET /x")
    Transaction.connection.select_one(Transaction.sanitize_sql_array([
      "SELECT * FROM transaction_hourly_stats WHERE project_id = ? AND transaction_name = ?",
      @project.id, name
    ]))
  end

  test "after_create live-bumps both aggregate tables" do
    create_txn(duration: 250, db_time: 40, view_time: 20, query_count: 3, http_status: "200")

    row = hourly_row
    assert_equal 1,   row["count"]
    assert_equal 250, row["sum_duration"]
    assert_equal 250, row["min_duration"]
    assert_equal 250, row["max_duration"]
    assert_equal 40,  row["sum_db_time"]
    assert_equal 1,   row["db_time_count"]
    assert_equal 3,   row["sum_query_count"]
    assert_equal 0,   row["error_count"]

    hist_total = Transaction.connection.select_value(
      "SELECT SUM(count) FROM transaction_histograms WHERE project_id = #{@project.id}"
    )
    assert_equal 1, hist_total
  end

  test "scalar aggregates are exact (count, avg, max, min, queries, errors)" do
    90.times { create_txn(duration: 100, db_time: 40, query_count: 2, http_status: "200") }
    10.times { create_txn(duration: 1000, has_n_plus_one: true, query_count: 50, http_status: "500") }

    stats = Transaction.percentiles_for_endpoint("GET /x", @range, project_id: @project.id)
    assert_equal 100,   stats["count"]
    assert_equal 190.0, stats["avg_duration"]      # (90*100 + 10*1000)/100
    assert_equal 1000,  stats["max_duration"]
    assert_equal 100,   stats["min_duration"]
    assert_equal 40.0,  stats["avg_db_time"]        # only the 90 non-null rows

    err = Transaction.total_and_error_count_in_range(time_range: @range, project_id: @project.id)
    assert_equal({ total: 100, errors: 10 }, err)
  end

  test "DDSketch percentiles land within the ~1% relative-error band" do
    100.times { create_txn(duration: 200) }
    stats = Transaction.percentiles_for_endpoint("GET /x", @range, project_id: @project.id)
    [stats["p50_duration"], stats["p95_duration"], stats["p99_duration"]].each do |p|
      assert_in_delta 200, p, 2, "percentile #{p} should be within ~1% of 200"
    end
  end

  test "percentiles reflect the distribution (skewed tail)" do
    90.times { create_txn(duration: 100) }
    10.times { create_txn(duration: 1000) }
    stats = Transaction.percentiles_for_endpoint("GET /x", @range, project_id: @project.id)
    assert_in_delta 100,  stats["p50_duration"], 2
    assert_in_delta 1000, stats["p95_duration"], 12  # ~1% of 1000
  end

  test "endpoint stats survive deletion of the raw transactions" do
    90.times { create_txn(duration: 100, db_time: 40) }
    10.times { create_txn(duration: 1000, has_n_plus_one: true, http_status: "500") }

    before = Transaction.percentiles_for_endpoint("GET /x", @range, project_id: @project.id)
    Transaction.where(project_id: @project.id).delete_all
    after = Transaction.percentiles_for_endpoint("GET /x", @range, project_id: @project.id)

    assert_equal before, after
    assert_equal 100, after["count"]
    assert_equal 1000, after["max_duration"]
  end

  test "impact ranking and N+1 worklist read from aggregates" do
    50.times { create_txn(name: "GET /slow", duration: 800, query_count: 5) }
    20.times { create_txn(name: "GET /slow", duration: 800, has_n_plus_one: true, query_count: 40) }
    100.times { create_txn(name: "GET /fast", duration: 10) }

    ranked = Transaction.stats_by_endpoint_with_impact(@range, project_id: @project.id)
    assert_equal "GET /slow", ranked.first["transaction_name"]  # higher avg*count
    slow = ranked.find { |r| r["transaction_name"] == "GET /slow" }
    assert_equal 70, slow["count"]
    assert_equal 20, slow["n_plus_one_count"]
    assert_equal 40, slow["max_queries"]

    npo = Transaction.endpoints_by_n_plus_one(@range, project_id: @project.id)
    row = npo.find { |r| r["transaction_name"] == "GET /slow" }
    assert_equal 20, row["n_plus_one_count"]
    assert_equal 70, row["total_count"]
  end

  test "p95_by_bucket and volume_by_bucket serve hourly sparklines from aggregates" do
    100.times { create_txn(duration: 200) }

    spark = Transaction.p95_by_bucket(transaction_names: ["GET /x"], time_range: @range, buckets: 24, project_id: @project.id)
    nonzero = spark["GET /x"].reject(&:zero?)
    assert_equal 1, nonzero.size, "all txns share one hour → one populated bucket"
    assert_in_delta 200, nonzero.first, 2

    vol = Transaction.volume_by_bucket(project_id: @project.id, time_range: @range, buckets: 24)
    assert_equal 100, vol.sum
    assert_equal 1, vol.reject(&:zero?).size
  end

  test "sub-hour windows fall back to the bounded raw path with the same algorithm" do
    # 30-minute window → 5-minute buckets (sub-hour): reads raw, not histogram.
    recent = 10.minutes.ago
    50.times { create_txn(duration: 300, at: recent) }
    short = (1.hour.ago)..Time.current
    series = Transaction.time_series_for_endpoint("GET /x", short, project_id: @project.id, buckets: 12)
    populated = series.reject { |b| b["count"].zero? }
    assert_equal 50, populated.sum { |b| b["count"] }
    populated.each { |b| assert_in_delta 300, b["p95"], 4 }
  end
end

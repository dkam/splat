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
      query_count: 0, has_n_plus_one: false, n_plus_one_time: nil, spans_truncated: false
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
      {duration: 1000, has_n_plus_one: true, n_plus_one_time: 96, query_count: 30, http_status: "500"}
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
    assert_equal 96, row["sum_n_plus_one_time"]
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

  # --- Lock contention (Booko report, 2026-09-12) -----------------------------
  #
  # RetentionJob holds write locks on transactions_spans for 3+ hours; this job
  # fires hourly at :05. busy_timeout is 5s and DispatchConsumer releases 5
  # times before burying, so each collision gave up after ~25s against a lock
  # held for hours. On 2026-09-09 that buried the job — and because tuber's
  # idempotency key is held by a buried job, the scheduler's next ~70 hourly
  # puts were all suppressed. The rollup was dead for three days.
  #
  # So: a busy error must not propagate (a raise means release → bury → the idp
  # key is held and nothing runs again), and a default run must cover a trailing
  # window, because an hour skipped under lock is otherwise never recounted —
  # each run targets exactly one hour and never looks back.

  test "a busy error is swallowed so the job is deleted rather than buried" do
    insert_raw([{duration: 100}])
    job = Analytics::HistogramRollupJob.new

    busy = ActiveRecord::StatementTimeout.new("SQLite3::BusyException: database is locked")
    raising_exec_query(busy) do
      assert_nothing_raised { job.perform(@hour) }
    end
  end

  test "a non-busy error still raises — only lock contention is tolerated" do
    insert_raw([{duration: 100}])
    job = Analytics::HistogramRollupJob.new

    boom = ActiveRecord::StatementInvalid.new("no such column: nonsense")
    raising_exec_query(boom) do
      assert_raises(ActiveRecord::StatementInvalid) { job.perform(@hour) }
    end
  end

  # Minitest 6 dropped #stub. with_stub (test_helper) re-installs the *original*
  # Method afterwards — a bare define_method/remove_method pair would strip
  # exec_query for the rest of this parallel worker and break the next test.
  def raising_exec_query(error, &block)
    with_stub(TransactionsSpansRecord.connection, :exec_query, ->(*) { raise error }, &block)
  end

  test "a default run recounts a trailing window, not just the previous hour" do
    # The hour that would have been skipped while retention held the lock.
    missed = (Time.current - 4.hours).beginning_of_hour
    insert_raw([{duration: 100, timestamp: missed}, {duration: 300, timestamp: missed}])

    Analytics::HistogramRollupJob.new.perform

    row = Transaction.connection.select_one(
      "SELECT * FROM transaction_hourly_stats WHERE project_id = #{@project.id} " \
      "AND hour_bucket = '#{missed.strftime("%Y-%m-%d %H:00:00")}'"
    )
    assert row, "an hour missed under lock must be recounted by a later run"
    assert_equal 2, row["count"]
    assert_equal 400, row["sum_duration"]
  end

  test "the trailing window is wide enough to outlast a retention run" do
    # Pointless as a self-heal if the window is shorter than the lock that
    # causes the misses — every run inside the retention pass would still fail
    # and no later run would reach back far enough.
    assert_operator Analytics::HistogramRollupJob::LOOKBACK_HOURS, :>=, 4
  end

  test "an explicit hour still rolls up exactly that hour" do
    other = (Time.current - 10.hours).beginning_of_hour
    insert_raw([{duration: 100, timestamp: @hour}, {duration: 900, timestamp: other}])

    Analytics::HistogramRollupJob.new.perform(@hour)

    rolled = Transaction.connection.select_value(
      "SELECT COUNT(*) FROM transaction_hourly_stats WHERE project_id = #{@project.id}"
    )
    assert_equal 1, rolled, "an explicit hour must not drag in the trailing window"
  end
end

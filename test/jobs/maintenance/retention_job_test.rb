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
    old_hour = (Time.current - 600.days).beginning_of_hour
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

  def create_span_tree(transaction_id:, timestamp:)
    SpanTree.create_from_tree!(project_id: @project.id, transaction_id: transaction_id,
      timestamp: timestamp, tree: {"trace_id" => "t", "spans" => []},
      span_count: 0, spans_truncated: false)
  end

  test "span_trees past the span cutoff are purged, recent kept" do
    Setting.instance.update!(spans_data_retention_days: 30)
    old = create_span_tree(transaction_id: "old-txn", timestamp: 60.days.ago)
    recent = create_span_tree(transaction_id: "recent-txn", timestamp: 1.day.ago)

    Maintenance::RetentionJob.new.perform

    refute SpanTree.exists?(old.id), "blob past the 30d span cutoff is purged"
    assert SpanTree.exists?(recent.id), "recent blob is retained"
  end

  test "span_trees are cascade-deleted with their aged-out transaction" do
    Setting.instance.update!(spans_data_retention_days: 30, transactions_data_retention_days: 90)
    txn = Transaction.create!(project: @project, transaction_id: "casc-txn",
      transaction_name: "GET /x", timestamp: 200.days.ago, duration: 100)
    # Blob is within the span window, but its transaction is past the 90d cutoff.
    blob = create_span_tree(transaction_id: "casc-txn", timestamp: 1.day.ago)

    Maintenance::RetentionJob.new.perform

    refute Transaction.exists?(txn.id)
    refute SpanTree.exists?(blob.id), "blob cascade-deleted with its transaction"
  end

  test "logs older than the logs cutoff are deleted, recent kept" do
    Setting.instance.update!(logs_data_retention_days: 14)
    old = Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: 30.days.ago,
      level: :info, source: "sentry", body: "old", payload: {})
    recent = Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: 1.day.ago,
      level: :info, source: "sentry", body: "recent", payload: {})

    Maintenance::RetentionJob.new.perform

    refute Log.exists?(old.id), "log past the 14d cutoff is purged"
    assert Log.exists?(recent.id), "recent log is retained"
  end

  # --- incremental_vacuum (Booko report, 2026-09-12) --------------------------
  #
  # The Booko notes read Splat's on-disk file sizes (logs 109 GB, spans 215 GB,
  # issues_events 26 GB) as retention falling behind. It isn't — every stream
  # tracks its configured window to within a day. The gap between file size and
  # live data was free pages never returned to the OS: auto_vacuum is
  # INCREMENTAL on these DBs, and this job ran `PRAGMA incremental_vacuum(1000)`
  # exactly once per database per day. Measured, one such call reclaims exactly
  # ONE page whatever N is, so that returned 4 KB/day against deletes freeing
  # several GB. issues_events had ~22 GB of free pages behind 3.58 GB of data.
  #
  # The loop is driven against a fake connection: whether SQLite reclaims a
  # given page is its business (and in WAL mode depends on checkpoint timing,
  # which a transactional test can't control), while the loop's stopping rules
  # are this job's business and are what regressed.
  class FakeConn
    attr_reader :steps, :checkpoints

    def initialize(freelist:, reclaim_per_step: 1)
      @freelist = freelist
      @reclaim = reclaim_per_step
      @steps = 0
      @checkpoints = 0
    end

    def execute(sql)
      if sql.include?("wal_checkpoint")
        @checkpoints += 1
        return
      end
      @steps += 1
      @freelist = [@freelist - @reclaim, 0].max
    end

    def select_value(_sql) = @freelist
  end

  def fake_base(conn)
    Class.new { define_singleton_method(:connection) { conn } }
  end

  test "vacuum keeps stepping until the freelist is drained" do
    conn = FakeConn.new(freelist: 10, reclaim_per_step: 1)
    result = Maintenance::RetentionJob.new.send(:vacuum, fake_base(conn), pages: 1, pause: 0)

    # The whole defect in one assertion: the old version issued exactly one
    # incremental_vacuum per database per daily run, so the freelist only grew.
    assert_equal 10, conn.steps, "vacuum must keep stepping, not reclaim once and stop"
    assert_equal 10, result[:freelist_before]
    assert_equal 0, result[:freelist_after]
  end

  test "vacuum checkpoints first, or there is nothing reclaimable to find" do
    conn = FakeConn.new(freelist: 3)
    Maintenance::RetentionJob.new.send(:vacuum, fake_base(conn), pages: 1, pause: 0)

    assert_equal 1, conn.checkpoints,
      "a free page the WAL still references can't be truncated out of the main file"
  end

  test "vacuum stops when a step reclaims nothing rather than spinning on its budget" do
    # WAL mode means not every free page is reclaimable right now, so the
    # freelist can stop falling well before zero. Without this break the loop
    # spins flat out until VACUUM_MAX_SECONDS, holding the connection for two
    # minutes and reclaiming nothing — worse than the bug it replaced.
    conn = FakeConn.new(freelist: 500, reclaim_per_step: 0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Maintenance::RetentionJob.new.send(:vacuum, fake_base(conn), pages: 1, pause: 0)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 1, conn.steps, "should give up after the first unproductive step"
    assert_equal 500, result[:freelist_after], "and leave the rest for the next run"
    assert_operator elapsed, :<, 5, "must not burn the full budget making no progress"
  end

  test "vacuum does no work at all when its budget is already spent" do
    conn = FakeConn.new(freelist: 10)
    result = Maintenance::RetentionJob.new.send(:vacuum, fake_base(conn), pages: 1, max_seconds: 0, pause: 0)

    assert_equal 0, conn.steps
    assert_equal 10, result[:freelist_after]
  end

  test "vacuum yields on lock contention instead of raising" do
    job = Maintenance::RetentionJob.new
    conn = LogsRecord.connection
    busy = ActiveRecord::StatementTimeout.new("SQLite3::BusyException: database is locked")

    with_stub(conn, :execute, ->(*) { raise busy }) do
      assert_nothing_raised { job.send(:vacuum, LogsRecord, pause: 0) }
    end
  end

  test "vacuum still swallows a non-contention failure without killing the run" do
    # Pre-existing behaviour: a DB without incremental auto_vacuum answers
    # "no such pragma"/similar — warn, don't abort the whole retention pass.
    job = Maintenance::RetentionJob.new
    conn = LogsRecord.connection
    boom = ActiveRecord::StatementInvalid.new("no such pragma")

    with_stub(conn, :execute, ->(*) { raise boom }) do
      assert_nothing_raised { job.send(:vacuum, LogsRecord, pause: 0) }
    end
  end

  test "vacuum runs against a real database without raising" do
    assert_nothing_raised { Maintenance::RetentionJob.new.send(:vacuum, LogsRecord, pause: 0) }
  end
end

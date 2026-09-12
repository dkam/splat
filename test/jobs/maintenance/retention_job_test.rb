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
    attr_reader :steps, :checkpoints, :checkpoint_modes

    # reclaim_after_checkpoints models the WAL pinning free pages: steps run and
    # report success, but the freelist does not fall until enough checkpoints
    # have copied the referencing frames back into the main file. This is the
    # production behaviour on 2026-09-12 that the old no-progress break read as
    # "nothing left to do" (see the stall tests below).
    def initialize(freelist:, reclaim_per_step: 1, reclaim_after_checkpoints: 0)
      @freelist = freelist
      @reclaim = reclaim_per_step
      @reclaim_after_checkpoints = reclaim_after_checkpoints
      @steps = 0
      @checkpoints = 0
      @checkpoint_modes = []
    end

    def execute(sql)
      if (mode = sql[/wal_checkpoint\((\w+)\)/, 1])
        @checkpoints += 1
        @checkpoint_modes << mode
        return
      end
      @steps += 1
      return if @checkpoints < @reclaim_after_checkpoints

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

  # --- stall recovery -------------------------------------------------------
  #
  # Production, 2026-09-12: the logs vacuum stopped after 1,696 steps reporting
  # "no further pages reclaimable", leaving 7,849,972 free pages (31.6 GB) in a
  # 109 GB file — and then LogsFtsOptimizeJob reclaimed 131,141 pages from that
  # same database three minutes later, having done nothing but wait for
  # WalCheckpointJob's ten-minute TRUNCATE. The pages were reclaimable all
  # along; the WAL was holding them and one checkpoint at the top of the run
  # wasn't enough. A stall is a reason to checkpoint again, not a reason to stop.

  test "vacuum re-checkpoints when progress stalls, instead of calling it a day" do
    # Reclaims nothing until a second checkpoint has run — the pages are free,
    # the WAL just still references them.
    conn = FakeConn.new(freelist: 10, reclaim_after_checkpoints: 2)

    result = Maintenance::RetentionJob.new.send(:vacuum, fake_base(conn), pages: 1, pause: 0)

    assert_equal 2, conn.checkpoints, "one before the loop, one to break the stall"
    assert_equal 0, result[:freelist_after],
      "the stall was recoverable — treating it as the end leaves the file bloated for another day"
  end

  test "vacuum gives up after a bounded number of stalled checkpoints" do
    # Nothing will ever be reclaimable here. Checkpointing is not free (TRUNCATE
    # waits on readers), so the retry has to be capped rather than left to run
    # out the clock.
    conn = FakeConn.new(freelist: 500, reclaim_per_step: 0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = Maintenance::RetentionJob.new.send(:vacuum, fake_base(conn), pages: 1, pause: 0)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 1 + Maintenance::RetentionJob::VACUUM_CHECKPOINT_RETRIES, conn.checkpoints,
      "the pre-loop checkpoint plus a fixed number of recovery attempts"
    assert_equal 1 + Maintenance::RetentionJob::VACUUM_CHECKPOINT_RETRIES, conn.steps,
      "one unproductive step per attempt and no more — never a spin on the freelist"
    assert_equal 500, result[:freelist_after], "and the rest is left for the next run"
    assert_operator elapsed, :<, 5, "must not burn the full budget making no progress"
  end

  test "the pre-vacuum checkpoint truncates the WAL rather than passing over it" do
    conn = FakeConn.new(freelist: 3)

    Maintenance::RetentionJob.new.send(:vacuum, fake_base(conn), pages: 1, pause: 0)

    assert_equal ["TRUNCATE"], conn.checkpoint_modes.uniq,
      "PASSIVE is what SQLite already does automatically and what already lost the race " \
      "(see Maintenance::WalCheckpointJob); it left 31.6 GB unreclaimed on 2026-09-12"
  end

  test "the per-database budget can absorb a night's worth of freed pages" do
    # Measured in production 2026-09-12: ~1,300 incremental_vacuum calls/sec at
    # one page each, and the periodic pause takes that to roughly 1,000
    # pages/sec sustained — call it 4 MB/s. A night's log retention deletes
    # ~776k rows, which frees on the order of 1.8 GB (~450k pages) before the
    # FTS index is counted, so ~450s of stepping just to stand still.
    #
    # The 120s this job shipped with bought ~640 MB: it went backwards every
    # night while appearing to work. The budget has to clear a night's deletes
    # with enough headroom to eat into the backlog, or the file only ever grows.
    assert_operator Maintenance::RetentionJob::VACUUM_MAX_SECONDS, :>=, 600,
      "a budget that cannot keep up with one night's deletes never drains the freelist"
  end
end

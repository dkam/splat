module Analytics
  # Hourly rollup of `transactions` rows into two aggregate tables, both keyed by
  # (project, endpoint, env, hour):
  #   * transaction_histograms   — per-bucket duration counts (percentiles)
  #   * transaction_hourly_stats — scalar aggregates (count, sums, max/min, …)
  #
  # Both are idempotent: re-running an hour rewrites that hour's rows via
  # ON CONFLICT … DO UPDATE SET <col> = excluded.<col>. The live ingest bumps
  # (Analytics::Histogram / Analytics::HourlyStats) keep the in-progress and
  # not-yet-rolled hours populated; this job is the authoritative recount.
  #
  # The histogram bucket formula is shared with the read path via
  # Analytics::Histogram.bucket_index_sql so writer and reader can't drift.
  class HistogramRollupJob
    class << self
      def insert_sql
        @insert_sql ||= <<~SQL
          INSERT INTO transaction_histograms (project_id, transaction_name, environment, hour_bucket, bucket_index, count)
          SELECT project_id,
                 transaction_name,
                 COALESCE(environment, '') AS environment,
                 strftime('%Y-%m-%d %H:00:00', timestamp) AS hour_bucket,
                 #{Analytics::Histogram.bucket_index_sql} AS bucket_index,
                 COUNT(*) AS count
            FROM transactions
           WHERE timestamp >= ? AND timestamp < ?
           GROUP BY 1, 2, 3, 4, 5
          ON CONFLICT(project_id, transaction_name, environment, hour_bucket, bucket_index)
          DO UPDATE SET count = excluded.count
        SQL
      end

      # Scalar companion. NULL db_time/view_time are summed as 0 but excluded
      # from their *_count, so AVG = sum/count matches raw AVG(col) (skips NULLs).
      # 5xx detection mirrors total_and_error_count_in_range (CAST status >= 500).
      def hourly_stats_sql
        @hourly_stats_sql ||= <<~SQL
          INSERT INTO transaction_hourly_stats
            (project_id, transaction_name, environment, hour_bucket,
             count, sum_duration, min_duration, max_duration,
             sum_db_time, db_time_count, sum_view_time, view_time_count,
             sum_query_count, max_query_count, n_plus_one_count, sum_n_plus_one_time, error_count)
          SELECT project_id,
                 transaction_name,
                 COALESCE(environment, '') AS environment,
                 strftime('%Y-%m-%d %H:00:00', timestamp) AS hour_bucket,
                 COUNT(*),
                 COALESCE(SUM(duration), 0),
                 MIN(duration),
                 COALESCE(MAX(duration), 0),
                 COALESCE(SUM(db_time), 0),
                 SUM(CASE WHEN db_time IS NOT NULL THEN 1 ELSE 0 END),
                 COALESCE(SUM(view_time), 0),
                 SUM(CASE WHEN view_time IS NOT NULL THEN 1 ELSE 0 END),
                 COALESCE(SUM(query_count), 0),
                 COALESCE(MAX(query_count), 0),
                 SUM(CASE WHEN has_n_plus_one THEN 1 ELSE 0 END),
                 COALESCE(SUM(n_plus_one_time), 0),
                 SUM(CASE WHEN CAST(http_status AS INTEGER) >= 500 THEN 1 ELSE 0 END)
            FROM transactions
           WHERE timestamp >= ? AND timestamp < ?
           GROUP BY 1, 2, 3, 4
          ON CONFLICT(project_id, transaction_name, environment, hour_bucket)
          DO UPDATE SET
            count = excluded.count,
            sum_duration = excluded.sum_duration,
            min_duration = excluded.min_duration,
            max_duration = excluded.max_duration,
            sum_db_time = excluded.sum_db_time,
            db_time_count = excluded.db_time_count,
            sum_view_time = excluded.sum_view_time,
            view_time_count = excluded.view_time_count,
            sum_query_count = excluded.sum_query_count,
            max_query_count = excluded.max_query_count,
            n_plus_one_count = excluded.n_plus_one_count,
            sum_n_plus_one_time = excluded.sum_n_plus_one_time,
            error_count = excluded.error_count
        SQL
      end
    end

    # How many hours back a default (scheduler-driven) run re-counts.
    #
    # Not just the previous hour, because Maintenance::RetentionJob holds write
    # locks on this DB for 3+ hours and this job fires hourly — so every run
    # inside a retention pass loses the race. A one-hour run never looks back,
    # which meant those hours kept the live-bump approximation and never got
    # their authoritative recount. Re-counting a trailing window is free
    # (every write is ON CONFLICT … DO UPDATE, i.e. idempotent) and self-heals
    # without needing a retry, a delay, or a second idempotency key.
    #
    # Keep this comfortably above a retention run's duration or the self-heal
    # can't work: every run in the window would fail and no later run would
    # reach back far enough.
    LOOKBACK_HOURS = 6

    # SQLite reports lock contention through several AR wrappers
    # (StatementTimeout and LockWaitTimeout are both StatementInvalid
    # subclasses), so match the message rather than the class.
    BUSY_MESSAGE = /database (?:table )?is locked|BusyException/i

    # Default: re-count the last LOOKBACK_HOURS completed hours, newest first.
    # Pass an explicit hour to roll up exactly that one.
    def perform(hour = nil)
      hours =
        if hour
          [Analytics::Histogram.hour_bucket(hour)]
        else
          latest = Analytics::Histogram.hour_bucket(1.hour.ago)
          Array.new(LOOKBACK_HOURS) { |i| latest - i.hours }
        end

      conn = TransactionsSpansRecord.connection
      done = 0

      # Newest first: the just-completed hour is the one this run exists for,
      # and the older hours are backfill that a later run can pick up again.
      hours.each do |h|
        rollup_hour(conn, h)
        done += 1
      rescue ActiveRecord::StatementInvalid => e
        # A raise here would propagate to DispatchConsumer, which releases the
        # job 5 times (~25s against a lock held for hours) and then buries it.
        # A buried job holds its tuber idempotency key, which silently
        # suppresses every subsequent scheduler put — on 2026-09-09 that killed
        # the rollup for three days. Swallow contention so the job is deleted
        # normally; the next hourly run re-counts what this one skipped.
        raise unless e.message.match?(BUSY_MESSAGE)

        Rails.logger.warn(
          "[HistogramRollupJob] database locked at #{h.iso8601} — " \
          "rolled up #{done}/#{hours.size} hour(s), leaving the rest to the next run"
        )
        break
      end

      {hours_requested: hours.size, hours_rolled_up: done}
    end

    private

    def rollup_hour(conn, hour)
      range = [hour, hour + 1.hour]
      Rails.logger.info "[HistogramRollupJob] rolling up #{range[0].iso8601}..#{range[1].iso8601}"
      conn.exec_query(self.class.insert_sql, "HistogramRollupJob histogram", range)
      conn.exec_query(self.class.hourly_stats_sql, "HistogramRollupJob hourly_stats", range)
    end
  end
end

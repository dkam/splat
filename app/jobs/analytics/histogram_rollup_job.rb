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
             sum_query_count, max_query_count, n_plus_one_count, error_count)
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
            error_count = excluded.error_count
        SQL
      end
    end

    # Default: roll up the most recently completed hour.
    def perform(hour = nil)
      hour = Analytics::Histogram.hour_bucket(hour || 1.hour.ago)
      range_start = hour
      range_end   = hour + 1.hour
      Rails.logger.info "[HistogramRollupJob] rolling up #{range_start.iso8601}..#{range_end.iso8601}"

      conn = TransactionsSpansRecord.connection
      conn.exec_query(self.class.insert_sql,      "HistogramRollupJob histogram",    [range_start, range_end])
      conn.exec_query(self.class.hourly_stats_sql, "HistogramRollupJob hourly_stats", [range_start, range_end])
    end
  end
end

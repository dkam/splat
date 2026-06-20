module Analytics
  # Hourly rollup of `transactions` rows into per-bucket counts in
  # `transaction_histograms`. Idempotent: re-running for an hour rewrites
  # that hour's bucket rows via ON CONFLICT … DO UPDATE SET count =
  # excluded.count.
  #
  # The bucket formula is shared with the read path (and Analytics::Histogram's
  # Ruby bump path) via Analytics::Histogram.bucket_index_sql, so writer and
  # reader can't drift. LN() is required — the percentile read queries use it
  # unconditionally, so there's no point guarding only the write with a Ruby
  # fallback; if LN were missing the app couldn't read histograms at all.
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
    end

    # Default: roll up the most recently completed hour.
    def perform(hour = nil)
      hour = Analytics::Histogram.hour_bucket(hour || 1.hour.ago)
      range_start = hour
      range_end   = hour + 1.hour
      Rails.logger.info "[HistogramRollupJob] rolling up #{range_start.iso8601}..#{range_end.iso8601}"

      TransactionsSpansRecord.connection.exec_query(
        self.class.insert_sql, "HistogramRollupJob", [range_start, range_end]
      )
    end
  end
end

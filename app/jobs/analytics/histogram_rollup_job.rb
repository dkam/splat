module Analytics
  # Hourly rollup of `transactions` rows into per-bucket counts in
  # `transaction_histograms`. Idempotent: re-running for an hour rewrites
  # that hour's bucket rows via ON CONFLICT … DO UPDATE SET count =
  # excluded.count.
  #
  # Bucket math matches Analytics::Histogram (GAMMA = 1.02):
  #   bucket_index = floor(ln(max(duration, 1)) / ln(1.02))
  # We compute the bucket in SQL when LN() is available; if not, we fall
  # back to a streaming Ruby tally.
  class HistogramRollupJob
    HAS_LN_QUERY = "SELECT LN(2.71)".freeze
    INSERT_SQL = <<~SQL.freeze
      INSERT INTO transaction_histograms (project_id, transaction_name, environment, hour_bucket, bucket_index, count)
      SELECT project_id,
             transaction_name,
             COALESCE(environment, '') AS environment,
             strftime('%Y-%m-%d %H:00:00', timestamp) AS hour_bucket,
             CAST(FLOOR(LN(MAX(duration, 1)) / LN(?)) AS INTEGER) AS bucket_index,
             COUNT(*) AS count
        FROM transactions
       WHERE timestamp >= ? AND timestamp < ?
       GROUP BY 1, 2, 3, 4, 5
      ON CONFLICT(project_id, transaction_name, environment, hour_bucket, bucket_index)
      DO UPDATE SET count = excluded.count
    SQL

    class << self
      def has_ln?
        return @has_ln unless @has_ln.nil?
        TransactionsSpansRecord.connection.select_value(HAS_LN_QUERY)
        @has_ln = true
      rescue ActiveRecord::StatementInvalid
        @has_ln = false
      end
    end

    # Default: roll up the most recently completed hour.
    def perform(hour = nil)
      hour = Analytics::Histogram.hour_bucket(hour || 1.hour.ago)
      range_start = hour
      range_end   = hour + 1.hour
      Rails.logger.info "[HistogramRollupJob] rolling up #{range_start.iso8601}..#{range_end.iso8601}"

      if self.class.has_ln?
        TransactionsSpansRecord.connection.exec_query(
          INSERT_SQL,
          "HistogramRollupJob",
          [Histogram::GAMMA, range_start, range_end]
        )
      else
        ruby_rollup(range_start, range_end)
      end
    end

    private

    # LN-less fallback: stream the window, tally in Ruby, upsert.
    def ruby_rollup(range_start, range_end)
      tally = Hash.new(0)
      Transaction.where(timestamp: range_start...range_end)
                 .pluck(:project_id, :transaction_name, :environment, :timestamp, :duration)
                 .each do |pid, name, env, ts, dur|
        key = [pid, name, env.to_s, Histogram.hour_bucket(ts), Histogram.bucket_index(dur)]
        tally[key] += 1
      end
      return if tally.empty?

      conn = TransactionsSpansRecord.connection
      sql = +"INSERT INTO transaction_histograms (project_id, transaction_name, environment, hour_bucket, bucket_index, count) VALUES "
      placeholders = []
      binds = []
      tally.each do |(pid, name, env, hour, bucket), count|
        placeholders << "(?, ?, ?, ?, ?, ?)"
        binds.push(pid, name, env, hour, bucket, count)
      end
      sql << placeholders.join(", ")
      sql << " ON CONFLICT(project_id, transaction_name, environment, hour_bucket, bucket_index)"
      sql << " DO UPDATE SET count = excluded.count"
      conn.exec_insert(sql, "HistogramRollupJob fallback", binds)
    end
  end
end

# frozen_string_literal: true

module DuckLake
  class Transaction < ApplicationDucklakeRecord
    self.table_name = "transactions"

    class << self
      def count_in_range(time_range: nil, project_id: nil)
        sql = +"SELECT COUNT(*) AS c FROM transactions"
        binds = []
        clauses = []

        if time_range
          clauses << "timestamp BETWEEN ? AND ?"
          binds << time_range.begin << time_range.end
        end
        if project_id.present?
          clauses << "project_id = ?"
          binds << project_id.to_i
        end

        sql << " WHERE " << clauses.join(" AND ") if clauses.any?
        (query(sql, *binds).first || {})["c"].to_i
      end

      def stats_by_endpoint(time_range = 24.hours.ago..Time.current, project_id: nil, limit: nil)
        sql = +<<~SQL
          SELECT
            transaction_name,
            AVG(duration)  AS avg_duration,
            MIN(duration)  AS min_duration,
            MAX(duration)  AS max_duration,
            COUNT(*)       AS count,
            AVG(db_time)   AS avg_db_time,
            AVG(view_time) AS avg_view_time
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
        SQL
        binds = [time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?\n"
          binds << project_id.to_i
        end

        sql << "GROUP BY transaction_name ORDER BY avg_duration DESC"
        sql << " LIMIT #{limit.to_i}" if limit

        query(sql, *binds)
      end

      def stats_by_endpoint_with_impact(time_range = 24.hours.ago..Time.current,
                                        project_id: nil, environment: nil, limit: nil)
        sql = +<<~SQL
          SELECT
            transaction_name,
            COUNT(*)                       AS count,
            AVG(duration)                  AS avg_duration,
            quantile_cont(duration, 0.95)  AS p95_duration,
            quantile_cont(duration, 0.99)  AS p99_duration,
            AVG(duration) * COUNT(*)       AS time_spent,
            #{n_plus_one_count_expr}       AS n_plus_one_count,
            AVG(#{queries_expr})           AS avg_queries,
            MAX(#{queries_expr})           AS max_queries
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
        SQL
        binds = [time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?\n"
          binds << project_id.to_i
        end
        if environment.present?
          sql << " AND environment = ?\n"
          binds << environment
        end

        sql << "GROUP BY transaction_name ORDER BY time_spent DESC"
        sql << " LIMIT #{limit.to_i}" if limit

        query(sql, *binds)
      end

      # Ranks endpoints by raw N+1 prevalence — for the "performance issues"
      # surface and the find_n_plus_one_endpoints MCP tool. Excludes endpoints
      # with zero N+1 hits so the result is a focused worklist.
      def endpoints_by_n_plus_one(time_range = 24.hours.ago..Time.current,
                                  project_id: nil, environment: nil, limit: 20)
        sql = +<<~SQL
          SELECT
            transaction_name,
            COUNT(*)                                       AS total_count,
            #{n_plus_one_count_expr}                       AS n_plus_one_count,
            ROUND(100.0 * #{n_plus_one_count_expr} / COUNT(*), 1) AS n_plus_one_pct,
            AVG(duration)                                  AS avg_duration,
            quantile_cont(duration, 0.95)                  AS p95_duration,
            quantile_cont(duration, 0.99)                  AS p99_duration,
            AVG(#{queries_expr})                           AS avg_queries,
            MAX(#{queries_expr})                           AS max_queries
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
        SQL
        binds = [time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?\n"
          binds << project_id.to_i
        end
        if environment.present?
          sql << " AND environment = ?\n"
          binds << environment
        end

        sql << "GROUP BY transaction_name HAVING n_plus_one_count > 0 ORDER BY n_plus_one_count DESC"
        sql << " LIMIT #{limit.to_i}" if limit

        query(sql, *binds)
      end

      private

      # SUM of transactions whose measurements.query_analysis.potential_n_plus_one
      # array is non-empty. measurements is JSON-typed in the schema but values
      # arrive as serialized strings via `to_json` in the dual-write — DuckDB
      # doesn't auto-coerce, so we cast explicitly.
      def n_plus_one_count_expr
        "SUM(CASE WHEN COALESCE(json_array_length(json_extract(CAST(measurements AS JSON), '$.query_analysis.potential_n_plus_one')), 0) > 0 THEN 1 ELSE 0 END)"
      end

      # Number of SQL queries per transaction, from measurements.query_analysis.total_queries.
      def queries_expr
        "COALESCE(CAST(json_extract(CAST(measurements AS JSON), '$.query_analysis.total_queries') AS INTEGER), 0)"
      end

      public

      def percentiles(time_range = 24.hours.ago..Time.current, project_id: nil)
        sql = +<<~SQL
          SELECT
            COUNT(*)                          AS count,
            AVG(duration)                     AS avg,
            quantile_cont(duration, 0.50)     AS p50,
            quantile_cont(duration, 0.95)     AS p95,
            quantile_cont(duration, 0.99)     AS p99,
            MIN(duration)                     AS min,
            MAX(duration)                     AS max
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
        SQL
        binds = [time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?"
          binds << project_id.to_i
        end

        row = query(sql, *binds).first || {}
        return {} if (row["count"] || 0).zero?

        {
          avg: row["avg"]&.to_f&.round(2) || 0,
          p50: row["p50"]&.to_f&.round(2) || 0,
          p95: row["p95"]&.to_f&.round(2) || 0,
          p99: row["p99"]&.to_f&.round(2) || 0,
          min: row["min"]&.to_f || 0,
          max: row["max"]&.to_f || 0
        }
      end

      def percentiles_for_endpoint(endpoint, time_range = 24.hours.ago..Time.current, project_id: nil, environment: nil, release: nil)
        sql = +<<~SQL
          SELECT
            COUNT(*)                          AS count,
            AVG(duration)                     AS avg_duration,
            quantile_cont(duration, 0.50)     AS p50_duration,
            quantile_cont(duration, 0.95)     AS p95_duration,
            quantile_cont(duration, 0.99)     AS p99_duration,
            MIN(duration)                     AS min_duration,
            MAX(duration)                     AS max_duration,
            AVG(db_time)                      AS avg_db_time,
            quantile_cont(db_time, 0.95)      AS p95_db_time,
            AVG(view_time)                    AS avg_view_time,
            quantile_cont(view_time, 0.95)    AS p95_view_time
          FROM transactions
          WHERE transaction_name = ?
            AND timestamp BETWEEN ? AND ?
        SQL
        binds = [endpoint, time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?"
          binds << project_id.to_i
        end
        if environment.present?
          sql << " AND environment = ?"
          binds << environment
        end
        if release.present?
          sql << " AND release = ?"
          binds << release
        end

        query(sql, *binds).first || {}
      end

      # Time-bucketed metrics for one endpoint — count + percentiles per bucket.
      # Bucket size is computed from the time range and bucket_count; missing
      # buckets are zero-filled so callers always get a complete series.
      def time_series_for_endpoint(endpoint, time_range = 24.hours.ago..Time.current,
                                   bucket_count: 24, project_id: nil, environment: nil, release: nil)
        bucket_seconds = ((time_range.end - time_range.begin) / bucket_count.to_f).to_f
        return [] if bucket_seconds <= 0

        sql = +<<~SQL
          SELECT
            CAST(floor((epoch(timestamp) - epoch(?::TIMESTAMP)) / ?) AS INTEGER) AS bucket_idx,
            COUNT(*)                       AS count,
            AVG(duration)                  AS avg_duration,
            quantile_cont(duration, 0.50)  AS p50_duration,
            quantile_cont(duration, 0.95)  AS p95_duration,
            quantile_cont(duration, 0.99)  AS p99_duration,
            MAX(duration)                  AS max_duration
          FROM transactions
          WHERE transaction_name = ?
            AND timestamp BETWEEN ? AND ?
        SQL
        binds = [time_range.begin, bucket_seconds, endpoint, time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?"
          binds << project_id.to_i
        end
        if environment.present?
          sql << " AND environment = ?"
          binds << environment
        end
        if release.present?
          sql << " AND release = ?"
          binds << release
        end

        sql << " GROUP BY bucket_idx ORDER BY bucket_idx"
        rows = query(sql, *binds)
        by_idx = rows.index_by { |r| r["bucket_idx"].to_i }

        Array.new(bucket_count) do |i|
          row = by_idx[i]
          bucket_start = time_range.begin + (i * bucket_seconds)
          {
            bucket_start: bucket_start,
            count: row ? row["count"].to_i : 0,
            avg_duration: row && row["avg_duration"]&.to_f,
            p50_duration: row && row["p50_duration"]&.to_f,
            p95_duration: row && row["p95_duration"]&.to_f,
            p99_duration: row && row["p99_duration"]&.to_f,
            max_duration: row && row["max_duration"]&.to_f
          }
        end
      end

      def response_time_by_hour(time_range = 24.hours.ago..Time.current, project_id: nil)
        sql = +<<~SQL
          SELECT
            strftime(timestamp, '%H:00')  AS hour_bucket,
            COUNT(*)                       AS request_count,
            AVG(duration)                  AS avg_duration,
            MAX(duration)                  AS max_duration
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
        SQL
        binds = [time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?"
          binds << project_id.to_i
        end

        sql << " GROUP BY hour_bucket ORDER BY hour_bucket"
        query(sql, *binds)
      end

      # Bucketed transaction counts keyed by transaction_name, for sparklines.
      # Returns { transaction_name => [count_in_bucket_0, count_in_bucket_1, ...] }
      # with a zero-filled array of length `buckets` for every name passed in.
      def counts_by_bucket(transaction_names:, time_range: 24.hours.ago..Time.current,
                           buckets: 24, project_id: nil, environment: nil)
        result = transaction_names.to_h { |n| [n, Array.new(buckets, 0)] }
        return result if transaction_names.blank?

        bucket_seconds = ((time_range.end - time_range.begin) / buckets.to_f).to_f
        return result if bucket_seconds <= 0

        placeholders = Array.new(transaction_names.size, "?").join(",")

        sql = +<<~SQL
          SELECT
            transaction_name,
            CAST(floor((epoch(timestamp) - epoch(?::TIMESTAMP)) / ?) AS INTEGER) AS bucket_idx,
            COUNT(*) AS c
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
            AND transaction_name IN (#{placeholders})
        SQL
        binds = [time_range.begin, bucket_seconds, time_range.begin, time_range.end, *transaction_names]

        if project_id.present?
          sql << " AND project_id = ?\n"
          binds << project_id.to_i
        end
        if environment.present?
          sql << " AND environment = ?\n"
          binds << environment
        end

        sql << "GROUP BY transaction_name, bucket_idx"

        query(sql, *binds).each do |row|
          name = row["transaction_name"]
          idx = row["bucket_idx"].to_i.clamp(0, buckets - 1)
          next unless result.key?(name)
          result[name][idx] = row["c"].to_i
        end

        result
      end

      def slow(min_duration_ms:, time_range: 24.hours.ago..Time.current, project_id: nil,
               endpoint: nil, http_status: nil, http_method: nil, environment: nil, limit: 50)
        sql = +<<~SQL
          SELECT *
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
            AND duration >= ?
        SQL
        binds = [time_range.begin, time_range.end, min_duration_ms.to_i]

        if project_id.present?
          sql << " AND project_id = ?"
          binds << project_id.to_i
        end
        if endpoint.present?
          sql << " AND transaction_name LIKE ?"
          binds << "%#{endpoint}%"
        end
        if http_status.present?
          sql << " AND http_status = ?"
          binds << http_status.to_s
        end
        if http_method.present?
          sql << " AND http_method = ?"
          binds << http_method.to_s
        end
        if environment.present?
          sql << " AND environment = ?"
          binds << environment.to_s
        end

        sql << " ORDER BY duration DESC LIMIT #{limit.to_i}"
        query(sql, *binds)
      end
    end
  end
end

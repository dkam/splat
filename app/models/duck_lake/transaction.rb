# frozen_string_literal: true

module DuckLake
  class Transaction < ApplicationDucklakeRecord
    self.table_name = "transactions"

    class << self
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

# frozen_string_literal: true

module DuckLake
  class Event < ApplicationParquetLakeRecord
    self.table_name = "events"

    class << self
      def count_in_range(time_range: nil, project_id: nil)
        sql = +"SELECT COUNT(*) AS c FROM #{from_clause}"
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

      # Project-wide bucketed event counts for the project dashboard sparkline.
      # Returns a flat zero-filled array of length `buckets`.
      def volume_by_bucket(time_range: 24.hours.ago..Time.current, buckets: 24, project_id: nil)
        result = Array.new(buckets, 0)
        bucket_seconds = ((time_range.end - time_range.begin) / buckets.to_f).to_f
        return result if bucket_seconds <= 0

        sql = +<<~SQL
          SELECT
            CAST(floor((epoch(timestamp) - epoch(?::TIMESTAMP)) / ?) AS INTEGER) AS bucket_idx,
            COUNT(*) AS c
          FROM #{from_clause}
          WHERE timestamp BETWEEN ? AND ?
        SQL
        binds = [time_range.begin, bucket_seconds, time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?"
          binds << project_id.to_i
        end

        sql << " GROUP BY bucket_idx"

        query(sql, *binds).each do |row|
          idx = row["bucket_idx"].to_i.clamp(0, buckets - 1)
          result[idx] = row["c"].to_i
        end
        result
      end

      # Bucketed event counts keyed by issue_id, for sparklines.
      # Returns { issue_id => [count_in_bucket_0, count_in_bucket_1, ...] }
      # with a zero-filled array of length `buckets` for every issue_id passed in,
      # even ones with no events in the range.
      def event_counts_by_bucket(issue_ids:, time_range: 24.hours.ago..Time.current,
                                 buckets: 24, project_id: nil)
        result = issue_ids.to_h { |id| [id.to_i, Array.new(buckets, 0)] }
        return result if issue_ids.blank?

        bucket_seconds = ((time_range.end - time_range.begin) / buckets.to_f).to_f
        return result if bucket_seconds <= 0

        id_list = issue_ids.map { |id| id.to_i }.join(",")

        sql = +<<~SQL
          SELECT
            issue_id,
            CAST(floor((epoch(timestamp) - epoch(?::TIMESTAMP)) / ?) AS INTEGER) AS bucket_idx,
            COUNT(*) AS c
          FROM #{from_clause}
          WHERE timestamp BETWEEN ? AND ?
            AND issue_id IN (#{id_list})
        SQL
        binds = [time_range.begin, bucket_seconds, time_range.begin, time_range.end]

        if project_id.present?
          sql << " AND project_id = ?\n"
          binds << project_id.to_i
        end

        sql << "GROUP BY issue_id, bucket_idx"

        query(sql, *binds).each do |row|
          issue_id = row["issue_id"].to_i
          idx = row["bucket_idx"].to_i.clamp(0, buckets - 1)
          next unless result.key?(issue_id)
          result[issue_id][idx] = row["c"].to_i
        end

        result
      end
    end
  end
end

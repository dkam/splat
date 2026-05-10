# frozen_string_literal: true

module DuckLake
  # Append-only span rows for a transaction's waterfall view.
  #
  # Lives only in DuckLake (no AR mirror) — span volume is 10–100×
  # transactions, and we only ever read spans by parent transaction
  # (not by id). Columnar storage handles both the size and the read
  # pattern well.
  #
  # Rows are written one transaction at a time via multi_insert, so
  # spans of one transaction land in the same Parquet row group and
  # repeated trace_id/transaction_id/project_id collapse via RLE.
  class Span < ApplicationDucklakeRecord
    self.table_name = "spans"

    # Fetch all spans for a transaction, ordered by sequence.
    # near_timestamp drives partition pruning (year/month of timestamp).
    # ±1 day is wider than needed for partition pruning alone, but spans are
    # stored timezone-naive while near_timestamp is UTC; the wide window
    # absorbs the offset. Tighten only after the storage tz is normalized.
    def self.for_transaction(transaction_id, project_id:, near_timestamp:)
      sql = <<~SQL
        SELECT
          span_id, parent_span_id, trace_id, transaction_id, project_id,
          timestamp, end_timestamp,
          (epoch(end_timestamp) - epoch(timestamp)) * 1000 AS duration_ms,
          op, status, description, tags, data, depth, sequence
        FROM spans
        WHERE transaction_id = ?
          AND project_id = ?
          AND timestamp BETWEEN ? AND ?
        ORDER BY sequence
      SQL
      query(sql, transaction_id, project_id, near_timestamp - 1.day, near_timestamp + 1.day)
    end
  end
end

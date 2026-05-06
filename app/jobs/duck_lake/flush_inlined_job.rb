# frozen_string_literal: true

module DuckLake
  # Periodic flush of inlined catalog rows into parquet. Splat's writes are
  # all small (single-row event/transaction inserts, ≤SPAN_CAP span batches),
  # so they always stay inline under DATA_INLINING_ROW_LIMIT. Without a
  # periodic flush the catalog SQLite grows unbounded and writes get slow.
  class FlushInlinedJob < ApplicationJob
    queue_as :low_priority

    LAKE = "splat_lake"

    def perform
      return if ApplicationDucklakeRecord.disabled?

      Rails.logger.info "[DuckLake] flush starting"
      start = Time.current

      ApplicationDucklakeRecord.execute("CALL ducklake_flush_inlined_data('#{LAKE}')")

      Rails.logger.info "[DuckLake] flush done in #{(Time.current - start).round(2)}s"
    rescue => e
      Rails.logger.error "[DuckLake] flush failed: #{e.class}: #{e.message}"
      # Don't re-raise — flush failures shouldn't take down the worker pool.
      # Next scheduled run will try again.
    end
  end
end

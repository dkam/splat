# frozen_string_literal: true

module DuckLake
  # Periodic maintenance for the DuckLake catalog. Issues a single CHECKPOINT
  # against the splat_lake attach — DuckLake flushes inlined rows across every
  # table, reclaims dead snapshots, and resets in-memory WAL pages in one
  # operation. Simpler than iterating ducklake_flush_inlined_data per table
  # and lets DuckLake schedule the work internally.
  #
  # Memory hygiene: CHECKPOINT can blow past DuckDB's default memory_limit on
  # large backlogs. We SET preserve_insertion_order=false (a flush doesn't
  # need ordered output) and SET threads=1 (single-threaded uses less peak
  # memory) on the connection before the CHECKPOINT call. If the worker has
  # DUCKDB_MEMORY_LIMIT set, that cap is honored — DuckDB spills to temp_dir
  # instead of growing unbounded.
  #
  # Kill switch: DUCKLAKE_FLUSH_DISABLED=true skips the checkpoint entirely.
  # Use when the catalog has grown past container memory and the worker is
  # in an OOM-restart loop — disabling lets UnifiedConsumer keep draining
  # the ingest queue while you give the worker enough RAM to catch up.
  # Distinct from DUCKLAKE_DISABLED, which no-ops all DuckLake activity.
  class FlushInlinedJob
    LAKE = "splat_lake"

    def self.disabled?
      ENV["DUCKLAKE_FLUSH_DISABLED"].to_s.match?(/\A(1|true|yes)\z/i)
    end

    def perform
      return if ApplicationDucklakeRecord.disabled?
      if self.class.disabled?
        Rails.logger.info "[DuckLake] checkpoint skipped (DUCKLAKE_FLUSH_DISABLED)"
        return
      end

      Rails.logger.info "[DuckLake] checkpoint starting"
      t0 = Time.current

      ApplicationDucklakeRecord.execute("SET preserve_insertion_order = false")
      ApplicationDucklakeRecord.execute("SET threads = 1")
      ApplicationDucklakeRecord.query("CHECKPOINT #{LAKE}")

      Rails.logger.info "[DuckLake] checkpoint done in #{(Time.current - t0).round(2)}s"
    rescue => e
      Rails.logger.error "[DuckLake] checkpoint failed: #{e.class}: #{e.message}"
    end
  end
end

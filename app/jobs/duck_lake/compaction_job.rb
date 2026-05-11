# frozen_string_literal: true

module DuckLake
  # Periodic parquet compaction. The 5-minute FlushInlinedJob produces a
  # steady stream of small parquet files; without compaction, query
  # performance degrades as DuckLake has to open more files per scan.
  #
  # ducklake_merge_adjacent_files merges files within the same partition
  # and same schema version. It does NOT cross partition boundaries, so
  # files that landed at the table root (e.g. flush output that bypassed
  # the PARTITIONED BY spec) only merge with other root-level files —
  # they don't migrate into year=YYYY/month=MM/ directories. Migrating
  # those is a separate one-shot rewrite, not part of this job.
  #
  # Old files are NOT deleted by this call; reclaiming disk needs a
  # separate cleanup step (TODO).
  class CompactionJob
    LAKE = "splat_lake"

    def perform
      return if ApplicationDucklakeRecord.disabled?

      Rails.logger.info "[DuckLake] compaction starting"
      start = Time.current

      ApplicationDucklakeRecord.execute("CALL ducklake_merge_adjacent_files('#{LAKE}')")

      Rails.logger.info "[DuckLake] compaction done in #{(Time.current - start).round(2)}s"
    rescue => e
      Rails.logger.error "[DuckLake] compaction failed: #{e.class}: #{e.message}"
    end
  end
end

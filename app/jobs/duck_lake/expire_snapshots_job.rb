# frozen_string_literal: true

module DuckLake
  # Periodic reclamation of dead snapshots in the DuckLake catalog. Every
  # write to the lake (flush, INSERT, DELETE, schema change) creates a new
  # ducklake_snapshot row; without expiry the catalog Postgres grows
  # monotonically — minute-frequency flushes alone produce ~1440 snapshots
  # per day per table. Expired snapshots also unblock orphaned parquet for
  # cleanup by CleanupOldFilesJob.
  #
  # Retention is set catalog-wide via `expire_older_than` (see
  # ApplicationDucklakeRecord::CATALOG_RETENTION_WINDOW) so this call
  # inherits the same window as CHECKPOINT and CleanupOldFilesJob.
  class ExpireSnapshotsJob
    def perform
      return if ApplicationDucklakeRecord.disabled?

      Rails.logger.info "[DuckLake] expire_snapshots starting"
      t0 = Time.current

      result = ApplicationDucklakeRecord.query(
        "CALL ducklake_expire_snapshots('#{ApplicationDucklakeRecord::CATALOG_NAME}')"
      )

      Rails.logger.info "[DuckLake] expire_snapshots done in #{(Time.current - t0).round(2)}s — #{result.inspect}"
    rescue => e
      Rails.logger.error "[DuckLake] expire_snapshots failed: #{e.class}: #{e.message}"
    end
  end
end

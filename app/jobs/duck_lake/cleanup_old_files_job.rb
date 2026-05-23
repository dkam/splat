# frozen_string_literal: true

module DuckLake
  # Daily cleanup of parquet files no longer referenced by any non-expired
  # snapshot. Without this, expired-but-unreferenced parquet accumulates on
  # disk indefinitely — the 62G / 15k-file blowup we saw came from missing
  # exactly this step.
  #
  # Runs daily rather than alongside expire_snapshots because:
  #   - Walking storage is the expensive part (S3 LIST or recursive readdir).
  #   - Snapshot expiry is cheap and benefits from running often (hourly).
  #   - There's no harm in unreferenced files lingering for ~24h before deletion.
  #
  # dry_run => false makes this destructive on the filesystem. The catalog
  # already knows the files are unreachable; this just reclaims the bytes.
  # Retention horizon is inherited from the catalog-wide delete_older_than
  # option set in ApplicationDucklakeRecord::CATALOG_RETENTION_WINDOW.
  class CleanupOldFilesJob
    LAKE = ApplicationDucklakeRecord::CATALOG_NAME

    def perform
      return if ApplicationDucklakeRecord.disabled?

      Rails.logger.info "[DuckLake] cleanup_old_files starting"
      t0 = Time.current

      result = ApplicationDucklakeRecord.query(
        "CALL ducklake_cleanup_old_files('#{LAKE}', dry_run => false)"
      )

      Rails.logger.info "[DuckLake] cleanup_old_files done in #{(Time.current - t0).round(2)}s — #{result.inspect}"
    rescue => e
      Rails.logger.error "[DuckLake] cleanup_old_files failed: #{e.class}: #{e.message}"
    end
  end
end

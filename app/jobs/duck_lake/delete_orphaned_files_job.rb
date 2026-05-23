# frozen_string_literal: true

module DuckLake
  # Safety net for parquet files that exist in storage but are not
  # referenced by any snapshot — typically the result of a crashed writer,
  # an interrupted flush, or a network glitch mid-PUT. CleanupOldFilesJob
  # doesn't touch these because it only targets files that *were* in a
  # snapshot and are now expired; truly never-committed files are
  # invisible to the catalog and need a storage walk to find.
  #
  # Retention is set catalog-wide via `delete_older_than` (see
  # ApplicationDucklakeRecord::CATALOG_RETENTION_WINDOW) so this call
  # inherits the same window as CHECKPOINT and CleanupOldFilesJob.
  #
  # Cheap on a healthy system (no orphans → no deletes), so daily is the
  # right cadence. The storage walk is the cost, not the deletes themselves.
  class DeleteOrphanedFilesJob
    LAKE = ApplicationDucklakeRecord::CATALOG_NAME

    def perform
      return if ApplicationDucklakeRecord.disabled?

      Rails.logger.info "[DuckLake] delete_orphaned_files starting"
      t0 = Time.current

      result = ApplicationDucklakeRecord.query(
        "CALL ducklake_delete_orphaned_files('#{LAKE}', dry_run => false)"
      )

      Rails.logger.info "[DuckLake] delete_orphaned_files done in #{(Time.current - t0).round(2)}s — #{result.inspect}"
    rescue => e
      Rails.logger.error "[DuckLake] delete_orphaned_files failed: #{e.class}: #{e.message}"
    end
  end
end

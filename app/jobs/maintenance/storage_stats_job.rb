module Maintenance
  # Recomputes the SQLite per-table size snapshot shown on the settings page
  # and stores it in SolidCache. The underlying `SELECT SUM(pgsize) FROM dbstat`
  # walks every page of each database file (O(file size) — seconds on the big
  # transactions/spans DB), so it must never run on the request path. The
  # settings controller reads the cached snapshot; this job keeps it fresh.
  class StorageStatsJob
    def perform
      start = Time.current
      snap = StorageStats.refresh!
      duration = (Time.current - start).round(2)
      Rails.logger.info(
        "[Maintenance::StorageStatsJob] done in #{duration}s — " \
        "total:#{snap[:total]} bytes, groups:#{snap[:groups].size}"
      )
      {duration: duration, total_bytes: snap[:total]}
    end
  end
end

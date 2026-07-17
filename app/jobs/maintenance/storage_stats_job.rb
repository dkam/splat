module Maintenance
  # Recomputes the SQLite storage snapshot shown on the settings page and stores
  # it in SolidCache. The settings controller only ever reads the cache; this
  # job keeps it fresh.
  #
  # Two modes, because the costs differ by orders of magnitude:
  #
  #   perform          — the cheap pass (hourly). Index seeks and PRAGMA reads.
  #   perform("deep")  — the full pass (daily, and on a cold cache). Walks every
  #                      page of every DB via dbstat and COUNT(*)s every table,
  #                      so it costs roughly two full reads of the whole dataset.
  #
  # The deep pass used to run every 15 minutes. Once the DBs passed ~100GB a
  # single pass took ~80 minutes, so the maintenance worker never idled and
  # every other job on the tube (histogram rollups, OIDC cleanup) was starved
  # behind it. Keep the deep pass daily.
  class StorageStatsJob
    def perform(mode = nil)
      deep = mode.to_s == "deep"
      start = Time.current
      snap = deep ? StorageStats.refresh_deep! : StorageStats.refresh!
      duration = (Time.current - start).round(2)
      Rails.logger.info(
        "[Maintenance::StorageStatsJob] #{deep ? "deep" : "fast"} done in #{duration}s — " \
        "total:#{snap[:total]} bytes, groups:#{snap[:groups].size}"
      )
      {duration: duration, total_bytes: snap[:total], deep: deep}
    end
  end
end

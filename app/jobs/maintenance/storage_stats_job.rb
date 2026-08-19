module Maintenance
  # Recomputes the SQLite storage snapshot shown on the settings page and stores
  # it in SolidCache. The settings controller only ever reads the cache; this
  # job keeps it fresh.
  #
  # Two modes, because the costs differ by orders of magnitude:
  #
  #   perform          — the cheap pass (hourly). Index seeks and PRAGMA reads.
  #   perform("deep")  — the full pass (weekly, and on a cold cache). Walks every
  #                      page of every DB via dbstat and COUNT(*)s every table,
  #                      so it costs roughly two full reads of the whole dataset.
  #
  # The deep pass used to run every 15 minutes, then daily. Once the DBs passed
  # ~100GB a single daily pass took ~8 hours at 277GB, running straight through
  # the morning peak — see config/schedule.yml for the current weekly cadence.
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

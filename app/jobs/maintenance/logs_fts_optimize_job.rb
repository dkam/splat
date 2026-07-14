module Maintenance
  # Nightly segment merge for the logs_fts FTS5 search index. RetentionJob's
  # log deletes only write delete-markers into the index — FTS5 never merges
  # old segments on its own, so dead entries accumulate without bound
  # (observed: 429 MB of logs_fts_data over ~3 MB of live log rows). 'optimize'
  # merges every segment into one and drops the dead entries; the follow-up
  # uncapped incremental_vacuum (the logs DB runs auto_vacuum=INCREMENTAL)
  # hands the freed pages back to the OS. Scheduled after data_retention so
  # each night's deletes get merged away the same night.
  class LogsFtsOptimizeJob
    def perform
      start = Time.current
      conn = LogsRecord.connection
      pages_before = conn.select_value("PRAGMA page_count").to_i
      conn.execute("INSERT INTO logs_fts(logs_fts) VALUES('optimize')")
      conn.execute("PRAGMA incremental_vacuum")
      pages_after = conn.select_value("PRAGMA page_count").to_i
      duration = (Time.current - start).round(2)
      Rails.logger.info(
        "[Maintenance::LogsFtsOptimizeJob] done in #{duration}s — " \
        "pages #{pages_before} -> #{pages_after}"
      )
      {duration: duration, pages_before: pages_before, pages_after: pages_after}
    rescue ActiveRecord::StatementInvalid => e
      # logs_fts may not exist (fresh DB before Logs::Fts.ensure! ran, or a
      # non-SQLite adapter) — skip rather than crash the maintenance worker.
      Rails.logger.warn "[Maintenance::LogsFtsOptimizeJob] skipped: #{e.message}"
      nil
    end
  end
end

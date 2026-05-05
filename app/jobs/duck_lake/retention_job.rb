# frozen_string_literal: true

module DuckLake
  # Independent retention pass for the DuckLake catalog. Schedules separately
  # from the AR DataRetentionJob so the two surfaces can have very different
  # horizons (AR is hot/short, DuckLake is cold/long).
  #
  # Note: DuckLake DELETEs are recorded in the catalog and filtered at read
  # time; reclaiming parquet bytes requires a separate compaction step which
  # we can run later if storage growth bites.
  class RetentionJob < ApplicationJob
    queue_as :low_priority

    def perform
      Rails.logger.info "[DuckLake] retention starting"
      start = Time.current
      setting = Setting.instance

      events_deleted = delete_older_than("events", setting.ducklake_events_cutoff_date)
      transactions_deleted = delete_older_than("transactions", setting.ducklake_transactions_cutoff_date)
      issues_deleted = delete_older_than("issues", setting.ducklake_issues_cutoff_date, column: "last_seen")
      spans_deleted = delete_older_than("spans", setting.ducklake_spans_cutoff_date)

      Rails.logger.info "[DuckLake] retention done in #{(Time.current - start).round(2)}s — " \
        "events=#{events_deleted} transactions=#{transactions_deleted} issues=#{issues_deleted} spans=#{spans_deleted}"

      {
        events_deleted: events_deleted,
        transactions_deleted: transactions_deleted,
        issues_deleted: issues_deleted,
        spans_deleted: spans_deleted
      }
    end

    private

    def delete_older_than(table, cutoff, column: "timestamp")
      before = ApplicationDucklakeRecord.query("SELECT COUNT(*) AS n FROM #{table}").first["n"]
      ApplicationDucklakeRecord.execute("DELETE FROM #{table} WHERE #{column} < ?", cutoff)
      after = ApplicationDucklakeRecord.query("SELECT COUNT(*) AS n FROM #{table}").first["n"]
      before - after
    end
  end
end

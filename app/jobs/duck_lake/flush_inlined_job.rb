# frozen_string_literal: true

module DuckLake
  # Periodic flush of inlined catalog rows into parquet. Splat's writes are
  # all small (single-row event/transaction inserts, ≤SPAN_CAP span batches),
  # so most stay inline under DATA_INLINING_ROW_LIMIT. Without a periodic
  # flush the catalog SQLite grows unbounded and writes get slow.
  #
  # Per-table flushing: `ducklake_flush_inlined_data` accepts `table_name =>`
  # but has no in-table chunking, so the smallest atomic unit is one table.
  # With a backlog that fits in memory the iteration is barely different from
  # a bulk call; with a backlog that *doesn't* fit, at least the smaller
  # tables can make progress before the big one OOMs the worker.
  #
  # Empty-table skip: we ask the catalog for per-table inlined row counts up
  # front. An empty-table `flush_inlined_data` call still allocates DuckDB
  # scratch buffers and takes tens of seconds — wasted both clock time and
  # memory headroom when the next table is the heavy one.
  #
  # Kill switch: DUCKLAKE_FLUSH_DISABLED=true skips the flush entirely. Use
  # when a single table's backlog has grown past container memory and the
  # worker is in an OOM-restart loop. Disabling flush lets the mirror
  # consumer keep draining the ingest queue (writes go inline, fine in the
  # short term); re-enable once you can give the worker enough RAM to drain
  # the one-off backlog. Distinct from DUCKLAKE_DISABLED, which no-ops all
  # DuckLake activity (no analytics, no dual writes).
  class FlushInlinedJob
    LAKE = ApplicationDucklakeRecord::CATALOG_NAME
    SCHEMA = "main"
    TABLES = %w[issues events transactions spans].freeze

    def self.disabled?
      ENV["DUCKLAKE_FLUSH_DISABLED"].to_s.match?(/\A(1|true|yes)\z/i)
    end

    def perform
      return if ApplicationDucklakeRecord.disabled?
      if self.class.disabled?
        Rails.logger.info "[DuckLake] flush skipped (DUCKLAKE_FLUSH_DISABLED)"
        return
      end

      Rails.logger.info "[DuckLake] flush starting"
      total_start = Time.current
      grand_total = 0

      tables_with_counts = inlined_counts_by_table

      # Process smallest-first so any OOM hits the heavy table last, after
      # the cheap ones have already made progress.
      tables_with_counts.sort_by { |_, count| count }.each do |table, expected|
        next if expected.zero?

        t0 = Time.current
        rows = flush_table(table)
        grand_total += rows
        Rails.logger.info "[DuckLake] flush #{table} → #{rows}/#{expected} rows in #{(Time.current - t0).round(2)}s"
      rescue => e
        Rails.logger.error "[DuckLake] flush #{table} failed: #{e.class}: #{e.message}"
      end

      Rails.logger.info "[DuckLake] flush done in #{(Time.current - total_start).round(2)}s (#{grand_total} rows)"
    end

    private

    def flush_table(table)
      result = ApplicationDucklakeRecord.query(
        "CALL ducklake_flush_inlined_data('#{LAKE}', schema_name => '#{SCHEMA}', table_name => '#{table}')"
      )
      # Older DuckLake versions return rows_flushed; newer may return
      # different column names — sum whatever numeric column we find, fall
      # back to row count if none match.
      first = result.first || {}
      key = first.keys.find { |k| k.to_s.match?(/row|count|flush/i) }
      key ? result.sum { |r| r[key].to_i } : result.size
    end

    # Returns { "events" => 12345, "transactions" => 0, ... }. The DuckLake
    # catalog holds a per-table inlined-rows table whose name is
    # `ducklake_inlined_data_<table_id>_<schema_version>`. We resolve the
    # mapping via ducklake_table → ducklake_inlined_data_tables, then run a
    # count on each. count(*) on a few-MB SQLite table is cheap.
    def inlined_counts_by_table
      counts = TABLES.to_h { |t| [t, 0] }

      mapping = ApplicationDucklakeRecord.query(<<~SQL)
        SELECT t.table_name AS source_table, idt.table_name AS inlined_table
        FROM __ducklake_metadata_splat_lake.main.ducklake_inlined_data_tables idt
        JOIN __ducklake_metadata_splat_lake.main.ducklake_table t
          ON t.table_id = idt.table_id
        WHERE t.end_snapshot IS NULL
      SQL

      mapping.each do |row|
        source = row["source_table"]
        inlined = row["inlined_table"]
        next unless counts.key?(source)

        result = ApplicationDucklakeRecord.query(
          "SELECT count(*) AS c FROM __ducklake_metadata_splat_lake.main.#{inlined}"
        )
        counts[source] += result.first["c"].to_i
      end

      counts
    rescue => e
      Rails.logger.error "[DuckLake] inlined_counts_by_table failed: #{e.class}: #{e.message} — falling back to flushing every table"
      TABLES.to_h { |t| [t, 1] }  # Non-zero so the loop still tries each.
    end
  end
end

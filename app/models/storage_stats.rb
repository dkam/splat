class StorageStats
  # Each entry is [label_for_ui, ActiveRecord base class]. The labels match
  # what the settings page renders as a section header.
  DBS = [
    ["Primary", "ApplicationRecord"],
    ["Issues + Events", "IssuesEventsRecord"],
    ["Transactions + Spans", "TransactionsSpansRecord"]
  ].freeze

  # Where the precomputed snapshot lives. SolidCache is SQLite-backed and
  # survives restarts, so the snapshot is the refresher's responsibility, not
  # a TTL's — Maintenance::StorageStatsJob rewrites it on a schedule. Bump the
  # version suffix if the snapshot shape changes.
  CACHE_KEY = "storage_stats/snapshot/v1"

  class << self
    # The precomputed snapshot the settings page renders, or nil if one has
    # never been built (fresh deploy with a cold cache). Cheap — a single
    # cache read, no dbstat scan.
    def snapshot
      Rails.cache.read(CACHE_KEY)
    end

    # Run the heavy dbstat scan now and store the result. Called by
    # Maintenance::StorageStatsJob; never on the request path. Returns the
    # stored snapshot.
    def refresh!
      groups = sqlite_tables_grouped
      total = groups.sum { |g| g[:tables].sum { |t| t[:total_bytes] } }
      snap = {groups: groups, total: total, collected_at: Time.current}
      Rails.cache.write(CACHE_KEY, snap)
      snap
    end

    # Ask the maintenance pool to (re)build the snapshot. Idempotent via the
    # tuber idp key, so a burst of cache-miss requests on a cold cache enqueues
    # at most one scan. Safe to call from a web request — it only puts a job.
    def enqueue_refresh
      Ingest::Tuber.put(
        Ingest::Tuber::MAINTENANCE_TUBE,
        {class: "Maintenance::StorageStatsJob", args: []},
        con: 1, idp: "storage_stats"
      )
    rescue => e
      Rails.logger.warn("StorageStats.enqueue_refresh failed: #{e.class}: #{e.message}")
    end

    # Tables across all three SQLite files, grouped by source DB so the
    # settings page can show them per-cluster. Each table row gives the row
    # count, table bytes, index bytes, and total bytes.
    def sqlite_tables_grouped
      DBS.map do |label, base_name|
        base = base_name.constantize
        {name: label, base: base_name, tables: sqlite_tables_for(base)}
      end
    end

    # Back-compat single-list view (primary only) — kept for any caller
    # not yet updated to the grouped form.
    def sqlite_tables
      sqlite_tables_for(ApplicationRecord)
    end

    private

    def sqlite_tables_for(base)
      conn = base.connection
      byte_map = page_bytes_by_object(conn)

      indexes_by_table = Hash.new { |h, k| h[k] = [] }
      conn.select_all("SELECT name, tbl_name FROM sqlite_master WHERE type = 'index'").each do |row|
        indexes_by_table[row["tbl_name"]] << row["name"]
      end

      tables = conn.select_all(<<~SQL).to_a
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name
      SQL

      tables.map { |row|
        name = row["name"]
        row_count = conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(name)}").to_i
        table_bytes = byte_map[name].to_i
        index_bytes = indexes_by_table[name].sum { |idx| byte_map[idx].to_i }
        {
          name: name,
          row_estimate: row_count,
          table_bytes: table_bytes,
          index_bytes: index_bytes,
          total_bytes: table_bytes + index_bytes
        }
      }.sort_by { |t| -t[:total_bytes] }
    end

    def page_bytes_by_object(conn)
      conn.select_all("SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name").each_with_object({}) do |row, h|
        h[row["name"]] = row["bytes"].to_i
      end
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("StorageStats: dbstat unavailable (#{e.class}: #{e.message}); per-table byte sizes will be 0")
      {}
    end
  end
end

class StorageStats
  # Each entry is [label_for_ui, ActiveRecord base class]. The labels match
  # what the settings page renders as a section header.
  DBS = [
    ["Primary",            "ApplicationRecord"],
    ["Issues + Events",    "IssuesEventsRecord"],
    ["Transactions + Spans", "TransactionsSpansRecord"]
  ].freeze

  class << self
    # Tables across all three SQLite files, grouped by source DB so the
    # settings page can show them per-cluster. Each table row gives the row
    # count, table bytes, index bytes, and total bytes.
    def sqlite_tables_grouped
      DBS.map do |label, base_name|
        base = base_name.constantize
        { name: label, base: base_name, tables: sqlite_tables_for(base) }
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

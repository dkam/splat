class StorageStats
  PARQUET_LAKE_TABLES = %w[events transactions spans].freeze

  class << self
    def sqlite_tables
      conn = ApplicationRecord.connection

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

    def parquet_lake_tables
      PARQUET_LAKE_TABLES.map { |table| parquet_lake_table_stats(table) }
    end

    private

    def page_bytes_by_object(conn)
      conn.select_all("SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name").each_with_object({}) do |row, h|
        h[row["name"]] = row["bytes"].to_i
      end
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("StorageStats: dbstat unavailable (#{e.class}: #{e.message}); per-table byte sizes will be 0")
      {}
    end

    # Walks the on-disk Parquet tree for one table and reports file count + total
    # bytes. No catalog query — each Parquet file is independent on disk.
    def parquet_lake_table_stats(table)
      pattern = File.join(ParquetLake::Connection.data_path, table, "**", "*.parquet")
      files = Dir.glob(pattern)
      sizes = files.map { |f| File.size(f) rescue 0 }
      {
        name: table,
        file_count: files.size,
        total_bytes: sizes.sum,
        max_file_bytes: sizes.max || 0
      }
    rescue => e
      Rails.logger.warn("StorageStats: parquet walk failed for #{table}: #{e.class} #{e.message}")
      {name: table, file_count: 0, total_bytes: 0, max_file_bytes: 0}
    end
  end
end

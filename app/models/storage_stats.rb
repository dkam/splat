class StorageStats
  DUCKLAKE_CATALOG = "splat_lake".freeze
  DUCKLAKE_TABLES = %w[events transactions spans issues].freeze

  class << self
    def postgres_tables
      sql = <<~SQL
        SELECT c.relname                       AS name,
               c.reltuples::bigint             AS row_estimate,
               pg_relation_size(c.oid)         AS table_bytes,
               pg_indexes_size(c.oid)          AS index_bytes,
               pg_total_relation_size(c.oid)   AS total_bytes
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'r' AND n.nspname = 'public'
        ORDER BY pg_total_relation_size(c.oid) DESC
      SQL

      ApplicationRecord.connection.select_all(sql).map do |row|
        {
          name: row["name"],
          row_estimate: row["row_estimate"].to_i,
          table_bytes: row["table_bytes"].to_i,
          index_bytes: row["index_bytes"].to_i,
          total_bytes: row["total_bytes"].to_i
        }
      end
    end

    def ducklake_tables
      DUCKLAKE_TABLES.map { |table| ducklake_table_stats(table) }
    end

    private

    def ducklake_table_stats(table)
      sql = <<~SQL
        SELECT COUNT(*)::BIGINT                             AS file_count,
               COALESCE(SUM(data_file_size_bytes), 0)::BIGINT   AS total_bytes,
               COALESCE(MAX(data_file_size_bytes), 0)::BIGINT   AS max_file_bytes,
               COUNT(delete_file)::BIGINT                       AS delete_file_count,
               COALESCE(SUM(delete_file_size_bytes), 0)::BIGINT AS delete_bytes
        FROM ducklake_list_files(?, ?)
      SQL

      row = ApplicationDucklakeRecord.query(sql, DUCKLAKE_CATALOG, table).first || {}

      {
        name: table,
        file_count: row["file_count"].to_i,
        total_bytes: row["total_bytes"].to_i,
        max_file_bytes: row["max_file_bytes"].to_i,
        delete_file_count: row["delete_file_count"].to_i,
        delete_bytes: row["delete_bytes"].to_i
      }
    rescue => e
      Rails.logger.warn("StorageStats: ducklake_list_files failed for #{table}: #{e.class} #{e.message}")
      { name: table, file_count: 0, total_bytes: 0, max_file_bytes: 0, delete_file_count: 0, delete_bytes: 0 }
    end
  end
end

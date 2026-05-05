# frozen_string_literal: true

# Base class for DuckLake-backed analytics models. Owns a single shared
# DuckDB::Database + Connection (guarded by a Mutex), bootstraps the lake on
# first use, and exposes a narrow insert/query/execute API.
#
# Subclasses set `self.table_name` and use the class-level API directly —
# there are no instances. Analytics call sites pass raw SQL to `query` and
# get back an array of hashes (column name => value).
class ApplicationDucklakeRecord
  class Error < StandardError; end
  class NotConfigured < Error; end

  class_attribute :table_name, instance_accessor: false

  @bootstrap_mutex  = Mutex.new
  @connection_mutex = Mutex.new
  @connection       = nil
  @database         = nil

  class << self
    # Kill switch — set DUCKLAKE_DISABLED=true to make every DuckLake call a
    # no-op. Used as an emergency rollback that doesn't require redeploying
    # an old image: dual-writes are skipped, analytics queries return [], and
    # bootstrap is never attempted (so no DuckDB::Database is ever created).
    def disabled?
      ENV["DUCKLAKE_DISABLED"].to_s.match?(/\A(1|true|yes)\z/i)
    end

    def bootstrap!
      raise Error, "DuckLake is disabled (DUCKLAKE_DISABLED=true)" if disabled?

      ApplicationDucklakeRecord.instance_variable_get(:@bootstrap_mutex).synchronize do
        return ApplicationDucklakeRecord.instance_variable_get(:@connection) if ApplicationDucklakeRecord.instance_variable_get(:@connection)
        if ApplicationDucklakeRecord.instance_variable_get(:@bootstrap_attempted)
          raise Error, "DuckLake bootstrap previously failed; restart the process to retry"
        end
        ApplicationDucklakeRecord.instance_variable_set(:@bootstrap_attempted, true)

        config = Rails.application.config.x.ducklake
        raise NotConfigured, "config/ducklake.yml not loaded" if config.blank?

        ensure_paths!(config)

        require "duckdb"
        database = DuckDB::Database.open
        # Pin the Database on the class ivar IMMEDIATELY after open. If we
        # let it go out of scope on a partial failure below, GC eventually
        # calls duckdb_close on it, which segfaults while joining DuckDB's
        # TaskScheduler threads. With it pinned, a failed bootstrap is just
        # an error — no orphan, no segfault.
        ApplicationDucklakeRecord.instance_variable_set(:@database, database)

        connection = database.connect
        configure_connection!(connection, config)
        attach_lake!(connection, config)
        load_schema!(connection)
        apply_partitioning!(connection)

        # Publish @connection only after the schema is fully loaded. Other
        # threads see nil until then and block on this mutex, instead of
        # racing in and querying tables that don't exist yet.
        ApplicationDucklakeRecord.instance_variable_set(:@connection, connection)
      end
      ApplicationDucklakeRecord.instance_variable_get(:@connection)
    end

    def connection
      ApplicationDucklakeRecord.instance_variable_get(:@connection) || bootstrap!
    end

    def insert(attrs)
      return false if disabled?
      raise Error, "table_name not set on #{name}" unless table_name

      cols = attrs.keys.map(&:to_s)
      placeholders = Array.new(cols.size, "?").join(", ")
      sql = "INSERT INTO #{table_name} (#{cols.join(", ")}) VALUES (#{placeholders})"
      values = attrs.values.map { |v| serialize(v) }

      with_lock { connection.execute(sql, *values) }
      true
    end

    def query(sql, *binds)
      return [] if disabled?

      with_lock do
        result = binds.empty? ? connection.query(sql) : connection.query(sql, *binds)
        columns = result.columns.map(&:name)
        result.each.map { |row| columns.zip(row).to_h }
      end
    end

    def execute(sql, *binds)
      return nil if disabled?

      with_lock do
        binds.empty? ? connection.execute(sql) : connection.execute(sql, *binds)
      end
    end

    private

    def with_lock(&block)
      ApplicationDucklakeRecord.instance_variable_get(:@connection_mutex).synchronize(&block)
    end

    def serialize(value)
      case value
      when Hash, Array then value.to_json
      else value
      end
    end

    def ensure_paths!(config)
      catalog = Rails.root.join(config[:catalog])
      FileUtils.mkdir_p(File.dirname(catalog))

      if config[:storage].to_s != "s3"
        FileUtils.mkdir_p(Rails.root.join(config[:data_path]))
      end
    end

    def configure_connection!(conn, config)
      conn.execute("INSTALL ducklake")
      conn.execute("LOAD ducklake")

      return unless config[:storage].to_s == "s3"

      conn.execute("INSTALL httpfs")
      conn.execute("LOAD httpfs")

      s3 = config[:s3] || {}
      conn.execute("SET s3_region = '#{quote(s3[:region])}'")                if s3[:region].present?
      conn.execute("SET s3_access_key_id = '#{quote(s3[:access_key_id])}'")  if s3[:access_key_id].present?
      conn.execute("SET s3_secret_access_key = '#{quote(s3[:secret_access_key])}'") if s3[:secret_access_key].present?
      conn.execute("SET s3_endpoint = '#{quote(s3[:endpoint])}'")            if s3[:endpoint].present?
    end

    def attach_lake!(conn, config)
      catalog = Rails.root.join(config[:catalog]).to_s
      data_path =
        if config[:storage].to_s == "s3"
          s3 = config[:s3] || {}
          prefix = s3[:prefix].to_s.sub(%r{/+\z}, "")
          "s3://#{s3[:bucket]}/#{prefix}/"
        else
          Rails.root.join(config[:data_path]).to_s.sub(%r{/+\z}, "") + "/"
        end

      options = ["DATA_PATH '#{quote(data_path)}'"]
      if (limit = config[:data_inlining_row_limit])
        options << "DATA_INLINING_ROW_LIMIT #{limit.to_i}"
      end

      conn.execute(
        "ATTACH IF NOT EXISTS 'ducklake:sqlite:#{quote(catalog)}' AS splat_lake (#{options.join(", ")})"
      )
      conn.execute("USE splat_lake")
    end

    def load_schema!(conn)
      schema_path = Rails.root.join("db", "ducklake_schema.sql")
      return unless schema_path.exist?

      schema_path.read.split(/;\s*\n/).each do |stmt|
        cleaned = stmt.lines.reject { |l| l.strip.start_with?("--") }.join.strip
        next if cleaned.empty?
        conn.execute(cleaned)
      end
    end

    # Apply year+month partitioning to events and transactions, skipping
    # tables that already have a current partition spec. DuckLake records
    # each ALTER as a new metadata snapshot, so we only ALTER when the
    # current spec is empty or different.
    PARTITIONED_TABLES = %w[events transactions].freeze
    PARTITION_TRANSFORMS = %w[year month].freeze

    def apply_partitioning!(conn)
      PARTITIONED_TABLES.each do |table|
        current = current_partition_transforms(conn, table)
        next if current == PARTITION_TRANSFORMS

        conn.execute(
          "ALTER TABLE #{table} SET PARTITIONED BY (year(timestamp), month(timestamp))"
        )
      end
    end

    def current_partition_transforms(conn, table)
      sql = <<~SQL
        SELECT pc.transform
        FROM __ducklake_metadata_splat_lake.main.ducklake_partition_info pi
        JOIN __ducklake_metadata_splat_lake.main.ducklake_partition_column pc
          ON pc.partition_id = pi.partition_id
        JOIN __ducklake_metadata_splat_lake.main.ducklake_table t
          ON t.table_id = pi.table_id
        WHERE t.table_name = '#{quote(table)}'
          AND pi.end_snapshot IS NULL
        ORDER BY pc.partition_key_index
      SQL
      result = conn.query(sql)
      result.each.map { |row| row.first }
    rescue
      []
    end

    def quote(str)
      str.to_s.gsub("'", "''")
    end
  end
end

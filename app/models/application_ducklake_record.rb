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
    def bootstrap!
      ApplicationDucklakeRecord.instance_variable_get(:@bootstrap_mutex).synchronize do
        return ApplicationDucklakeRecord.instance_variable_get(:@connection) if ApplicationDucklakeRecord.instance_variable_get(:@connection)

        config = Rails.application.config.x.ducklake
        raise NotConfigured, "config/ducklake.yml not loaded" if config.blank?

        ensure_paths!(config)

        require "duckdb"
        database = DuckDB::Database.open
        connection = database.connect

        configure_connection!(connection, config)
        attach_lake!(connection, config)
        load_schema!(connection)

        ApplicationDucklakeRecord.instance_variable_set(:@database, database)
        ApplicationDucklakeRecord.instance_variable_set(:@connection, connection)
      end
      ApplicationDucklakeRecord.instance_variable_get(:@connection)
    end

    def connection
      ApplicationDucklakeRecord.instance_variable_get(:@connection) || bootstrap!
    end

    def insert(attrs)
      raise Error, "table_name not set on #{name}" unless table_name

      cols = attrs.keys.map(&:to_s)
      placeholders = Array.new(cols.size, "?").join(", ")
      sql = "INSERT INTO #{table_name} (#{cols.join(", ")}) VALUES (#{placeholders})"
      values = attrs.values.map { |v| serialize(v) }

      with_lock { connection.execute(sql, *values) }
      true
    end

    def query(sql, *binds)
      with_lock do
        result = binds.empty? ? connection.query(sql) : connection.query(sql, *binds)
        columns = result.columns.map(&:name)
        result.each.map { |row| columns.zip(row).to_h }
      end
    end

    def execute(sql, *binds)
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

    def quote(str)
      str.to_s.gsub("'", "''")
    end
  end
end

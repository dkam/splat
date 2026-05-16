# frozen_string_literal: true

# Base class for DuckLake-backed analytics models. Owns a single shared
# DuckDB::Database; each thread gets its own DuckDB::Connection off it,
# attached to the same lake. Catalog backend is Postgres — DuckLake's
# concurrent-write story is built on the catalog backend's own MVCC,
# so no Ruby-side write mutex is needed.
#
# Subclasses set `self.table_name` and use the class-level API directly —
# there are no instances. Analytics call sites pass raw SQL to `query` and
# get back an array of hashes (column name => value).
class ApplicationDucklakeRecord
  class Error < StandardError; end
  class NotConfigured < Error; end

  class_attribute :table_name, instance_accessor: false

  CATALOG_NAME = "splat_lake"

  @bootstrap_mutex = Mutex.new
  @database        = nil
  @config          = nil

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
        return ApplicationDucklakeRecord.instance_variable_get(:@database) if ApplicationDucklakeRecord.instance_variable_get(:@database)
        if ApplicationDucklakeRecord.instance_variable_get(:@bootstrap_attempted)
          raise Error, "DuckLake bootstrap previously failed; restart the process to retry"
        end
        ApplicationDucklakeRecord.instance_variable_set(:@bootstrap_attempted, true)

        config = Rails.application.config.x.ducklake
        raise NotConfigured, "config/ducklake.yml not loaded" if config.blank?

        ensure_data_path!(config)

        require "duckdb"
        database = DuckDB::Database.open
        # Pin the Database on the class ivar IMMEDIATELY after open. If we
        # let it go out of scope on a partial failure below, GC eventually
        # calls duckdb_close on it, which segfaults while joining DuckDB's
        # TaskScheduler threads. With it pinned, a failed bootstrap is just
        # an error — no orphan, no segfault.
        ApplicationDucklakeRecord.instance_variable_set(:@database, database)
        ApplicationDucklakeRecord.instance_variable_set(:@config, config)

        # Primer connection runs schema + partitioning once. Per-thread
        # connections each prepare themselves (LOAD + ATTACH) on first use.
        primer = database.connect
        prepare_connection!(primer, config)
        load_schema!(primer)
        ensure_columns!(primer)
        apply_partitioning!(primer)
        apply_catalog_options!(primer)
      end
      ApplicationDucklakeRecord.instance_variable_get(:@database)
    end

    def connection
      Thread.current[:ducklake_conn] ||= begin
        bootstrap! unless ApplicationDucklakeRecord.instance_variable_get(:@database)
        database = ApplicationDucklakeRecord.instance_variable_get(:@database)
        config = ApplicationDucklakeRecord.instance_variable_get(:@config)
        conn = database.connect
        prepare_connection!(conn, config)
        conn
      end
    end

    # DuckLake's per-query attach pattern doesn't reliably preserve
    # `USE splat_lake` across calls — successive queries can land back
    # in DuckDB's default catalog and bare table names then fail with
    # "Table with name <foo> does not exist". Re-issuing USE before
    # each call is a cheap, branch-friendly defense; the alternative
    # is rewriting every SELECT/INSERT to use splat_lake.main.<table>.
    def use_lake!
      connection.execute("USE splat_lake")
    end

    def insert(attrs)
      return false if disabled?
      raise Error, "table_name not set on #{name}" unless table_name

      cols = attrs.keys.map(&:to_s)
      placeholders = Array.new(cols.size, "?").join(", ")
      sql = "INSERT INTO #{table_name} (#{cols.join(", ")}) VALUES (#{placeholders})"
      values = attrs.values.map { |v| serialize(v) }

      use_lake!
      connection.execute(sql, *values)
      true
    end

    # Bulk insert: writes many rows in a single VALUES (...), (...), ... INSERT.
    # All rows must share the same set of keys (uses keys of the first row).
    # One round-trip and — importantly for compression — one Parquet row group
    # cluster, so RLE/dictionary encoding can crush the repeating fields.
    def multi_insert(rows)
      return false if disabled?
      raise Error, "table_name not set on #{name}" unless table_name
      return true if rows.empty?

      key_order = rows.first.keys
      cols = key_order.map(&:to_s)
      placeholders = "(#{Array.new(cols.size, "?").join(", ")})"
      sql = "INSERT INTO #{table_name} (#{cols.join(", ")}) VALUES " +
            Array.new(rows.size, placeholders).join(", ")
      binds = rows.flat_map { |r| key_order.map { |k| serialize(r[k]) } }

      use_lake!
      connection.execute(sql, *binds)
      true
    end

    def query(sql, *binds)
      return [] if disabled?

      use_lake!
      result = binds.empty? ? connection.query(sql) : connection.query(sql, *binds)
      columns = result.columns.map(&:name)
      result.each.map { |row| columns.zip(row).to_h }
    end

    def execute(sql, *binds)
      return nil if disabled?
      use_lake!
      binds.empty? ? connection.execute(sql) : connection.execute(sql, *binds)
    end

    private

    # Per-connection setup: LOAD extensions, S3 config, ATTACH the lake,
    # USE the catalog. INSTALL is once-per-database in bootstrap!.
    def prepare_connection!(conn, config)
      configure_connection!(conn, config)
      attach_lake!(conn, config)
    end

    def serialize(value)
      case value
      when Hash, Array then value.to_json
      else value
      end
    end

    def ensure_data_path!(config)
      return if config[:storage].to_s == "s3"
      FileUtils.mkdir_p(Rails.root.join(config[:data_path]))
    end

    def configure_connection!(conn, config)
      conn.execute("INSTALL ducklake")
      conn.execute("LOAD ducklake")
      conn.execute("INSTALL postgres")
      conn.execute("LOAD postgres")

      # DuckDB defaults memory_limit to ~80% of physical RAM and threads to
      # physical cores PER CONNECTION. The ducklake worker has 5 consumer
      # threads each holding its own connection. With a generous container
      # mem_limit (4GB+) the defaults are fine; if you're memory-constrained,
      # set DUCKDB_MEMORY_LIMIT (e.g. "256MB") and DUCKDB_THREADS (e.g. 1)
      # to clamp per-connection budgets.
      if (memory_limit = ENV["DUCKDB_MEMORY_LIMIT"])
        conn.execute("SET memory_limit = '#{quote(memory_limit)}'")
      end
      if (threads_per_conn = ENV["DUCKDB_THREADS"])
        conn.execute("SET threads = #{threads_per_conn.to_i}")
      end

      # DuckDB spills to disk when a query's working set exceeds memory_limit.
      # The default `temp_directory` is `.tmp` relative to the process working
      # directory — in the container that's `/rails`, which is root-owned, so
      # the rails-uid process can't create it. The first time a flush needs
      # to spill, DuckDB fails to write the spill file and the OS OOM-killer
      # takes the container. Point temp_directory at a writable path.
      # `/rails/storage` is bind-mounted from the host and writable.
      temp_dir = ENV.fetch("DUCKDB_TEMP_DIR", Rails.root.join("storage", "duckdb_tmp").to_s)
      FileUtils.mkdir_p(temp_dir)
      conn.execute("SET temp_directory = '#{quote(temp_dir)}'")

      # DuckLake commits a new catalog snapshot per write; under burst load
      # (event/transaction/span ingest from many workers concurrently) the
      # default 10-retry optimistic-concurrency loop exceeds. Bump to 100;
      # collisions are still rare, retries are cheap, and 10× headroom
      # absorbs a backlog catch-up without losing writes.
      conn.execute("SET ducklake_max_retry_count = 100")

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

      # Per-thread connections each ATTACH the lake. The user alias
      # `splat_lake` propagates at database-instance level, so sibling
      # connections see it after the primer attaches. IF NOT EXISTS skips
      # the redundant ATTACH; the swallow handles the occasional
      # "already exists" raised when DuckLake's internal metadata DB is
      # registered before the alias check runs.
      begin
        conn.execute(
          "ATTACH IF NOT EXISTS '#{catalog_uri(config)}' AS splat_lake (#{options.join(", ")})"
        )
      rescue DuckDB::Error => e
        raise unless e.message.include?("already exists")
      end
      conn.execute("USE splat_lake")
    end

    # Build the DuckLake catalog ATTACH URI from the catalog config hash.
    # libpq-style key=value pairs after `ducklake:postgres:` — order is
    # insignificant. Password is included only if set so credential-less
    # peer-auth setups still work.
    def catalog_uri(config)
      catalog = config[:catalog]
      parts = []
      parts << "host=#{catalog[:host]}"        if catalog[:host].present?
      parts << "port=#{catalog[:port]}"        if catalog[:port].present?
      parts << "dbname=#{catalog[:database]}"  if catalog[:database].present?
      parts << "user=#{catalog[:user]}"        if catalog[:user].present?
      parts << "password=#{catalog[:password]}" if catalog[:password].present?
      "ducklake:postgres:#{parts.join(' ')}"
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
    PARTITIONED_TABLES = %w[events transactions spans].freeze
    PARTITION_TRANSFORMS = %w[year month].freeze

    # Idempotent column adds for evolving DuckLake-only tables (transactions,
    # spans). DuckDB doesn't accept DEFAULT clauses on ALTER TABLE ADD COLUMN,
    # so we check existence first then ADD bare + SET DEFAULT separately.
    SCHEMA_COLUMN_ADDITIONS = [
      ["transactions", "spans_truncated", "BOOLEAN", "FALSE"],
      ["transactions", "query_count",    "INTEGER", "0"],
      ["transactions", "has_n_plus_one", "BOOLEAN", "FALSE"]
    ].freeze

    def ensure_columns!(conn)
      SCHEMA_COLUMN_ADDITIONS.each do |table, column, type, default|
        present = conn.query(
          "SELECT 1 FROM duckdb_columns() WHERE table_name = '#{quote(table)}' AND column_name = '#{quote(column)}'"
        ).any?
        next if present
        conn.execute("ALTER TABLE #{table} ADD COLUMN #{column} #{type}")
        conn.execute("ALTER TABLE #{table} ALTER COLUMN #{column} SET DEFAULT #{default}")
      end
    end

    def apply_partitioning!(conn)
      PARTITIONED_TABLES.each do |table|
        current = current_partition_transforms(conn, table)
        next if current == PARTITION_TRANSFORMS

        conn.execute(
          "ALTER TABLE #{table} SET PARTITIONED BY (year(timestamp), month(timestamp))"
        )
      end
    end

    # Sets the catalog-wide retention windows used by CHECKPOINT and the
    # ducklake_expire_snapshots / ducklake_cleanup_old_files /
    # ducklake_delete_orphaned_files functions when called without an
    # explicit older_than arg. Splat doesn't use snapshot history — pages
    # and MCP tools query current data only — so a tight window keeps
    # parquet count and disk usage low without risking in-flight readers
    # (our queries finish in well under a second).
    CATALOG_RETENTION_WINDOW = "5 minutes"

    def apply_catalog_options!(conn)
      %w[expire_older_than delete_older_than].each do |opt|
        conn.execute("CALL #{CATALOG_NAME}.set_option(?, ?)", opt, CATALOG_RETENTION_WINDOW)
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

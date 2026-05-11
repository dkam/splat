# frozen_string_literal: true

# Base class for DuckLake-backed analytics models. Owns a single shared
# DuckDB::Database; each thread gets its own DuckDB::Connection off it,
# attached to the same lake. DuckLake handles concurrent reads/writes via
# its catalog snapshot model — no Ruby-side mutex needed on the hot path.
#
# Subclasses set `self.table_name` and use the class-level API directly —
# there are no instances. Analytics call sites pass raw SQL to `query` and
# get back an array of hashes (column name => value).
class ApplicationDucklakeRecord
  class Error < StandardError; end
  class NotConfigured < Error; end

  class_attribute :table_name, instance_accessor: false

  @bootstrap_mutex = Mutex.new
  # A Ruby-side @write_mutex previously serialized writes to absorb
  # SQLITE_BUSY errors. In practice it amplified flush-induced stalls: when
  # a long catalog operation held the SQLite write lock, the consumer
  # holding @write_mutex blocked on SQLite inside DuckDB, parking every
  # other consumer on the futex. DuckLake's attach+retry-on-busy is the
  # designed strategy; let it do its job and inserts proceed in parallel.
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

        ensure_paths!(config)
        ensure_catalog_wal_mode!(config)

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

    # Transient catalog-lock errors from DuckLake's per-query attach pattern.
    # Bursty concurrent commits can hit "database is locked" mid-transaction;
    # DuckLake retries some, propagates others. Absorb up to BUSY_RETRIES with
    # exponential backoff before letting the consumer release the batch.
    BUSY_RETRIES = 8
    BUSY_BASE_SLEEP_S = 0.05

    def insert(attrs)
      return false if disabled?
      raise Error, "table_name not set on #{name}" unless table_name

      cols = attrs.keys.map(&:to_s)
      placeholders = Array.new(cols.size, "?").join(", ")
      sql = "INSERT INTO #{table_name} (#{cols.join(", ")}) VALUES (#{placeholders})"
      values = attrs.values.map { |v| serialize(v) }

      with_busy_retry { connection.execute(sql, *values) }
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

      with_busy_retry { connection.execute(sql, *binds) }
      true
    end

    def query(sql, *binds)
      return [] if disabled?

      result = binds.empty? ? connection.query(sql) : connection.query(sql, *binds)
      columns = result.columns.map(&:name)
      result.each.map { |row| columns.zip(row).to_h }
    end

    def execute(sql, *binds)
      return nil if disabled?
      binds.empty? ? connection.execute(sql) : connection.execute(sql, *binds)
    end

    # Retained as an alias of execute; callers were updated when the Ruby-side
    # @write_mutex was removed. DuckLake's per-query attach + retry-on-busy
    # handles concurrent SQLite catalog access without app-level serialization.
    alias_method :execute_unlocked, :execute

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

    # Retry a write on transient catalog-lock errors. DuckLake serializes
    # catalog commits through SQLite; concurrent committers can see
    # "database is locked" or "Failed to commit DuckLake transaction"
    # depending on which layer surfaces the conflict first. Exponential
    # backoff up to BUSY_RETRIES; after that the consumer's own retry
    # path takes over (job goes back on the tube).
    def with_busy_retry
      attempt = 0
      begin
        yield
      rescue DuckDB::Error => e
        msg = e.message.to_s
        raise unless msg.include?("database is locked") ||
                     msg.include?("Failed to commit DuckLake transaction")
        attempt += 1
        raise if attempt > BUSY_RETRIES
        sleep BUSY_BASE_SLEEP_S * (2**(attempt - 1))
        retry
      end
    end

    def ensure_paths!(config)
      catalog = Rails.root.join(config[:catalog])
      FileUtils.mkdir_p(File.dirname(catalog))

      if config[:storage].to_s != "s3"
        FileUtils.mkdir_p(Rails.root.join(config[:data_path]))
      end
    end

    # Set the catalog SQLite to WAL mode before DuckLake attaches it. Default
    # rollback-journal mode is single-writer; under concurrent worker writes
    # DuckLake's catalog commits hit "database is locked" constantly. WAL is
    # persistent in the file header, so this is a no-op once set.
    def ensure_catalog_wal_mode!(config)
      catalog = Rails.root.join(config[:catalog]).to_s
      return unless File.exist?(catalog) || File.writable?(File.dirname(catalog))

      require "sqlite3"
      db = SQLite3::Database.new(catalog)
      db.execute("PRAGMA journal_mode=WAL")
      db.execute("PRAGMA synchronous=NORMAL")
      db.close
    rescue => e
      Rails.logger.warn "[DuckLake] could not set catalog WAL mode: #{e.class}: #{e.message}"
    end

    def configure_connection!(conn, config)
      conn.execute("INSTALL ducklake")
      conn.execute("LOAD ducklake")

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

      # Per-thread connections each ATTACH the lake. `IF NOT EXISTS` only
      # checks the user alias `splat_lake`, but DuckLake's internal metadata
      # DB `__ducklake_metadata_splat_lake` is created at database-instance
      # level, not per-connection. After the primer attaches, sibling
      # connections see the alias as missing but the metadata DB as already
      # present and ATTACH errors with "already exists". Normally
      # `USE splat_lake` works because the alias propagates from the
      # primer. Under concurrent per-thread setup that propagation races,
      # and USE can fail with "No catalog + schema named splat_lake". Treat
      # that as "alias not yet visible to this connection" and retry briefly.
      attach_attempts = 0
      begin
        begin
          conn.execute(
            "ATTACH IF NOT EXISTS 'ducklake:sqlite:#{quote(catalog)}' AS splat_lake (#{options.join(", ")})"
          )
        rescue DuckDB::Error => e
          raise unless e.message.include?("already exists")
        end
        conn.execute("USE splat_lake")
      rescue DuckDB::Error => e
        raise unless e.message.include?('No catalog + schema named "splat_lake"')
        attach_attempts += 1
        raise if attach_attempts > 10
        sleep 0.05 * attach_attempts
        retry
      end
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

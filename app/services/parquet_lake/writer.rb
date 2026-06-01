# frozen_string_literal: true

module ParquetLake
  # Writes a batch of rows to one Parquet file per (table, day-partition).
  #
  # Called once per UnifiedConsumer batch (~500 rows). Each invocation:
  #   1. Groups rows by year/month/day of `timestamp`.
  #   2. For each group, writes a UUIDv7-named Parquet file via DuckDB's
  #      COPY (SELECT ...) TO '<path>' (FORMAT PARQUET, COMPRESSION ZSTD).
  #   3. Writes to "<uuid>.parquet.tmp" first, then atomically renames to
  #      "<uuid>.parquet" so glob-based readers never see partial files.
  #
  # Multiple writer threads (or processes) can write to the same partition
  # directory concurrently without contention: UUIDv7 names never collide,
  # and POSIX rename is atomic within a filesystem.
  class Writer
    # Column types per table, mirroring db/ducklake_schema.sql. Used to
    # anchor types in the COPY's SELECT list so Parquet files have consistent
    # schemas across batches even when a batch has all-NULL columns (where
    # DuckDB's VALUES-based type inference would otherwise land on VARCHAR).
    SCHEMAS = {
      "events" => {
        id:               "BIGINT",
        event_id:         "VARCHAR",
        project_id:       "INTEGER",
        issue_id:         "BIGINT",
        timestamp:        "TIMESTAMP",
        duration:         "INTEGER",
        environment:      "VARCHAR",
        exception_type:   "VARCHAR",
        exception_value:  "VARCHAR",
        fingerprint:      "VARCHAR",
        message:          "VARCHAR",
        platform:         "VARCHAR",
        release:          "VARCHAR",
        sdk_name:         "VARCHAR",
        sdk_version:      "VARCHAR",
        server_name:      "VARCHAR",
        transaction_name: "VARCHAR",
        payload:          "JSON",
        created_at:       "TIMESTAMP",
        updated_at:       "TIMESTAMP"
      }.freeze,

      "transactions" => {
        id:               "BIGINT",
        transaction_id:   "VARCHAR",
        project_id:       "INTEGER",
        timestamp:        "TIMESTAMP",
        transaction_name: "VARCHAR",
        op:               "VARCHAR",
        duration:         "INTEGER",
        db_time:          "INTEGER",
        view_time:        "INTEGER",
        environment:      "VARCHAR",
        release:          "VARCHAR",
        server_name:      "VARCHAR",
        http_method:      "VARCHAR",
        http_status:      "VARCHAR",
        http_url:         "VARCHAR",
        tags:             "JSON",
        measurements:     "JSON",
        spans_truncated:  "BOOLEAN",
        query_count:      "INTEGER",
        has_n_plus_one:   "BOOLEAN",
        created_at:       "TIMESTAMP",
        updated_at:       "TIMESTAMP"
      }.freeze,

      "spans" => {
        project_id:     "INTEGER",
        trace_id:       "VARCHAR",
        transaction_id: "VARCHAR",
        span_id:        "VARCHAR",
        parent_span_id: "VARCHAR",
        timestamp:      "TIMESTAMP",
        end_timestamp:  "TIMESTAMP",
        op:             "VARCHAR",
        status:         "VARCHAR",
        description:    "VARCHAR",
        tags:           "JSON",
        data:           "JSON",
        depth:          "INTEGER",
        sequence:       "INTEGER",
        created_at:     "TIMESTAMP"
      }.freeze
    }.freeze

    class << self
      def write(table:, rows:)
        return false if disabled?
        return true if rows.nil? || rows.empty?

        table = table.to_s
        schema = SCHEMAS.fetch(table) { raise ArgumentError, "ParquetLake::Writer: unknown table #{table.inspect}" }

        group_by_partition(rows).each do |partition, partition_rows|
          write_partition(table, schema, partition, partition_rows)
        end
        true
      end

      def disabled?
        Connection.disabled? || ENV["PARQUET_LAKE_DISABLED"].to_s.match?(/\A(1|true|yes)\z/i)
      end

      private

      def write_partition(table, schema, partition, rows)
        partition_dir = File.join(Connection.data_path, table, partition)
        FileUtils.mkdir_p(partition_dir)

        uuid = SecureRandom.uuid_v7
        tmp_path   = File.join(partition_dir, ".#{uuid}.parquet.tmp")
        final_path = File.join(partition_dir, "#{uuid}.parquet")

        cols = schema.keys
        select_list = cols.map { |c| "CAST(#{c} AS #{schema[c]}) AS #{c}" }.join(", ")
        placeholders = "(#{Array.new(cols.size, "?").join(", ")})"
        values_clause = Array.new(rows.size, placeholders).join(", ")
        binds = rows.flat_map { |r| cols.map { |k| serialize(r[k] || r[k.to_s]) } }

        sql = <<~SQL
          COPY (
            SELECT #{select_list}
            FROM (VALUES #{values_clause}) AS t(#{cols.join(", ")})
          ) TO '#{escape(tmp_path)}' (FORMAT PARQUET, COMPRESSION ZSTD)
        SQL

        Connection.execute(sql, *binds)
        File.rename(tmp_path, final_path)
      ensure
        # If COPY threw, the .tmp file may still exist — clean it up so
        # partitions don't accumulate junk on repeat failures.
        File.unlink(tmp_path) if tmp_path && File.exist?(tmp_path) && !File.exist?(final_path)
      end

      def group_by_partition(rows)
        rows.group_by { |r| partition_for(r) }
      end

      # Hive-partitioning convention: year=YYYY/month=M/day=D with unpadded
      # month and day (matches what DuckDB itself emits with PARTITION_BY and
      # what read_parquet(hive_partitioning=true) parses out as virtual cols).
      def partition_for(row)
        ts = parse_time(row[:timestamp] || row["timestamp"])
        "year=#{ts.year}/month=#{ts.month}/day=#{ts.day}"
      end

      def parse_time(ts)
        case ts
        when Time             then ts
        when DateTime         then ts.to_time
        when String           then Time.parse(ts)
        when ActiveSupport::TimeWithZone then ts.to_time
        when nil              then raise ArgumentError, "ParquetLake::Writer: row has no timestamp"
        else                       ts.respond_to?(:to_time) ? ts.to_time : (raise ArgumentError, "unparseable timestamp: #{ts.inspect}")
        end
      end

      # Mirror ApplicationDucklakeRecord#serialize — Hash/Array become JSON
      # strings; everything else passes through to the duckdb-ruby binder.
      def serialize(value)
        case value
        when Hash, Array then value.to_json
        else value
        end
      end

      def escape(s)
        s.to_s.gsub("'", "''")
      end
    end
  end
end

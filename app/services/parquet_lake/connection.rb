# frozen_string_literal: true

module ParquetLake
  # Thread-local DuckDB connection holder for the Parquet-backed analytics
  # surface. No DuckLake extension, no shared catalog file — the connection
  # is a stock DuckDB instance whose only job is to run read_parquet() over
  # a partitioned tree on local disk (and COPY ... TO ... when the Writer
  # uses it).
  #
  # All connections share one in-process DuckDB::Database so DuckDB's task
  # scheduler is created once; per-thread connections off that database are
  # independent and don't contend on any shared lock (there is no catalog).
  class Connection
    @database         = nil
    @bootstrap_mutex  = Mutex.new

    class << self
      # Emergency disable switch — set PARQUET_LAKE_DISABLED=true to make every
      # analytics call a no-op (returns [] for reads, false for writes). Used
      # the same way DUCKLAKE_DISABLED was: a rollback that doesn't require
      # redeploying.
      def disabled?
        ENV["PARQUET_LAKE_DISABLED"].to_s.match?(/\A(1|true|yes)\z/i)
      end

      # Absolute filesystem path of the parquet root, e.g.
      # "/rails/storage/parquet_lake". Per-table data lives under
      # <data_path>/<table>/year=YYYY/month=M/day=D/<uuid>.parquet.
      def data_path
        Rails.root.join(config.fetch(:data_path)).to_s.sub(%r{/+\z}, "")
      end

      # Glob suitable for read_parquet(..., hive_partitioning=true).
      def glob_for(table)
        File.join(data_path, table.to_s, "**", "*.parquet")
      end

      # Run a SELECT and return [{column_name => value}, ...]. Matches the
      # legacy ApplicationDucklakeRecord.query signature so reader models can
      # swap their parent class with no other change at the call site.
      #
      # Returns [] when read_parquet hits a glob with no matching files —
      # the expected state on a fresh deploy, after retention rm -rf's old
      # partitions, or for a table that hasn't ingested anything yet. Better
      # to 0-render the page than to 500 it.
      def query(sql, *binds)
        return [] if disabled?
        result = binds.empty? ? connection.query(sql) : connection.query(sql, *binds)
        columns = result.columns.map(&:name)
        result.each.map { |row| columns.zip(row).to_h }
      rescue DuckDB::Error => e
        return [] if empty_glob_error?(e)
        raise
      end

      # Run a statement without expecting a result set. Used by the Writer
      # for COPY ... TO ....
      def execute(sql, *binds)
        return nil if disabled?
        binds.empty? ? connection.execute(sql) : connection.execute(sql, *binds)
      end

      # Drop this thread's connection so the next call rebuilds it. Used by
      # tests that swap the data_path between examples.
      def reset!
        Thread.current[:parquet_lake_conn] = nil
      end

      # Drop the shared Database too. Tests only — production never calls this.
      def reset_database!
        @bootstrap_mutex.synchronize do
          # Close every thread-local conn we can see, then drop the DB. We
          # can't reach other threads' Thread.current, but tests are single-
          # threaded so this clears the only live conn.
          Thread.current[:parquet_lake_conn] = nil
          @database = nil
        end
      end

      private

      def connection
        Thread.current[:parquet_lake_conn] ||= begin
          bootstrap!
          conn = @database.connect
          configure_connection!(conn)
          conn
        end
      end

      def bootstrap!
        return @database if @database
        @bootstrap_mutex.synchronize do
          return @database if @database
          require "duckdb"
          @database = DuckDB::Database.open
        end
      end

      # Mirrors the relevant parts of ApplicationDucklakeRecord#configure_connection!
      # — memory/threads/temp dir. No DuckLake INSTALL/LOAD, no S3 config (we're
      # local-disk only by plan decision).
      def configure_connection!(conn)
        if (memory_limit = ENV["DUCKDB_MEMORY_LIMIT"])
          conn.execute("SET memory_limit = '#{escape(memory_limit)}'")
        end
        if (threads = ENV["DUCKDB_THREADS"])
          conn.execute("SET threads = #{threads.to_i}")
        end
        temp_dir = ENV.fetch("DUCKDB_TEMP_DIR", Rails.root.join("storage", "duckdb_tmp").to_s)
        FileUtils.mkdir_p(temp_dir)
        conn.execute("SET temp_directory = '#{escape(temp_dir)}'")
      end

      def config
        cfg = Rails.application.config.x.parquet_lake
        return cfg if cfg.present?
        raise "ParquetLake not configured — config/parquet_lake.yml missing or empty"
      end

      def escape(s)
        s.to_s.gsub("'", "''")
      end

      # DuckDB's "No files found that match the pattern" surfaces as
      # DuckDB::Error with that text in the message. It fires for both
      # the empty-data-path case and the case where one table has files
      # but another doesn't — independent per-glob, so a query against
      # `events` can succeed while one against `spans` returns []. Both
      # are correct "no data" answers.
      def empty_glob_error?(e)
        e.message.to_s.include?("No files found that match the pattern")
      end
    end
  end
end

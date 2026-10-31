# frozen_string_literal: true

require "concurrent/map"

module Logs
  # Logs live in one SQLite file per UTC day of ingest (ADR 0005):
  # storage/log_days/2026-10-28.sqlite3 and so on. Retention deletes whole files, so
  # nothing ever deletes a row, and none of the FTS delete-markers, merges,
  # vacuum loops and freelists that one long-lived file needed can build up.
  #
  # Each file is a LogsRecord shard, registered at runtime the first time it's
  # touched. Inside DayFiles.write or Shard#with, Log and its scopes work
  # unchanged. LogsRecord's default shard is the catalog database, which holds
  # no logs table, so a Log query run outside a day file fails rather than
  # quietly reading nothing.
  #
  # A log's file is the day of its log_id, a UUIDv7 minted at ingest, so the
  # log_id alone names the file it's in. Partitioning on ingest day rather than
  # the log's own timestamp means only today's file is ever written, and a late
  # log never reopens a closed day. Its timestamp can still fall on the day
  # before, so a time-range read goes by each file's own timestamp bounds (see
  # Shard#bounds) rather than by its name.
  #
  # The logs database from before 0005 is one more shard, `legacy`, while it
  # ages out: read, never written, deleted whole by retention.
  module DayFiles
    SHARD_PREFIX = "logs_"
    LEGACY_SHARD = :logs_legacy
    NAME = /\A(\d{4}-\d{2}-\d{2})\.sqlite3\z/
    # The first 48 bits of a UUIDv7 are its Unix time in milliseconds.
    UUID_V7 = /\A(\h{8})-(\h{4})-7\h{3}-[89ab]\h{3}-\h{12}\z/i

    # Kept in step with the pre-0005 logs table, less attrs_text (which went
    # only to the index) and updated_at (rows are never updated), so the one Log
    # model reads both. `id` isn't AUTOINCREMENT: no row is ever deleted, so a
    # rowid is never reused anyway.
    #
    # Indexes: a file holds one day, so a timestamp-led index walks a day rather
    # than the whole retention window, and most of the old ones aren't worth
    # their bytes. test/models/log_query_plan_test.rb holds the plans these
    # exist for.
    #
    # logs_fts is contentless (content=''): it keeps the index and not a copy
    # of the text, so body and attrs_text are written to it at insert, and its
    # columns read back NULL. The body the views show is the logs column.
    #
    # Each file records SCHEMA_VERSION as its user_version, and nothing reads
    # it yet. Log's columns come from today's file, so the first column added
    # here has to be added to every older file as it's opened (keyed on
    # user_version), or selecting it fails there.
    SCHEMA = <<~SQL
      CREATE TABLE logs (
        id integer PRIMARY KEY NOT NULL,
        project_id integer NOT NULL,
        log_id varchar,
        timestamp datetime(6) NOT NULL,
        level integer,
        severity_number integer,
        body text,
        logger_name varchar,
        trace_id varchar,
        span_id varchar,
        environment varchar,
        release varchar,
        server_name varchar,
        source varchar,
        service varchar,
        duration_ms float,
        payload_blob blob,
        dict_id bigint,
        created_at datetime(6) NOT NULL
      );
      CREATE INDEX index_logs_on_project_id_and_timestamp ON logs (project_id, timestamp);
      CREATE INDEX index_logs_on_timestamp ON logs (timestamp);
      CREATE INDEX index_logs_on_project_id_and_level_and_timestamp ON logs (project_id, level, timestamp);
      CREATE INDEX index_logs_on_project_id_and_release_and_timestamp ON logs (project_id, release, timestamp);
      CREATE INDEX index_logs_on_trace_id ON logs (trace_id);
      CREATE INDEX index_logs_on_log_id ON logs (log_id);
      CREATE INDEX index_logs_on_project_id_and_duration_ms ON logs (project_id, duration_ms) WHERE duration_ms IS NOT NULL;
      CREATE VIRTUAL TABLE logs_fts USING fts5(body, attrs_text, content='');
    SQL
    SCHEMA_VERSION = 1

    # One day file, or the legacy database (day nil).
    Shard = Data.define(:name, :day, :path) do
      def legacy? = day.nil?

      # Runs the block with LogsRecord, and so Log, pointed at this file. Under
      # an MCP call's statement timeout, the file's connection gets what's left
      # of the call's time (SqliteStatementTimeout.cover).
      def with(&block)
        LogsRecord.connected_to(role: :writing, shard: name) do
          SqliteStatementTimeout.cover(LogsRecord)
          block.call
        end
      end

      # [oldest, newest] timestamp in the file, or nil when it holds no rows.
      def bounds = DayFiles.bounds(self)

      # When the file stops changing: an hour after its day ends. Ingest mints
      # a log's log_id and inserts it in the same job, so only a job under way
      # at midnight writes to a day once it's over. nil for the legacy database.
      def closed_at = day && (day + 1).in_time_zone("UTC") + 1.hour

      def closed? = !legacy? && Time.now >= closed_at
    end

    # Set up front, not on first use: two threads' first calls racing to build
    # these would each register the same file, and the second registration
    # closes the first's connections.
    @registered = Concurrent::Map.new
    @bounds_cache = Concurrent::Map.new
    @mutex = Mutex.new

    class << self
      # Where the day files live: the `day_files` key of the logs entry in
      # config/database.yml. Tests point each parallel worker at its own.
      def root
        @root ||= Rails.root.join(catalog_config.fetch(:day_files))
      end

      def root=(path)
        registered.each_key { |name| unregister(name) }
        bounds_cache.clear
        @root = path && Pathname(path)
      end

      # The pre-0005 logs database, if it's still there: the `legacy_database`
      # key of the logs entry.
      def legacy_path
        return @legacy_path if defined?(@legacy_path)

        path = catalog_config[:legacy_database]
        @legacy_path = path && Rails.root.join(path)
      end

      def legacy_path=(path)
        unregister(LEGACY_SHARD)
        @legacy_logs = nil
        @legacy_path = path && Pathname(path)
      end

      def path_for(day) = root.join("#{day.iso8601}.sqlite3")

      # Days with a file, oldest first.
      def days
        return [] unless root.directory?

        root.children.filter_map { |p| (m = NAME.match(p.basename.to_s)) && Date.iso8601(m[1]) }.sort
      end

      # Every shard there is, newest day first and the legacy database last.
      # Files retention has deleted since the last call are dropped here, so
      # each process lets go of them the next time it looks.
      def shards
        prune!
        [*days.reverse.map { |day| register(shard_for(day)) }, legacy_shard].compact
      end

      # The legacy database's shard, or nil once it has gone.
      def legacy_shard
        register(Shard.new(name: LEGACY_SHARD, day: nil, path: legacy_path)) if legacy_logs?
      end

      # The shard holding a log_id, by the day it names — nil when the log_id
      # isn't a UUIDv7 or that day has no file.
      def shard_for_log_id(log_id)
        day = day_for(log_id)
        (day && path_for(day).file?) ? register(shard_for(day)) : nil
      end

      # The UTC day a UUIDv7 was minted, or nil for anything else.
      def day_for(log_id)
        m = UUID_V7.match(log_id.to_s) or return nil
        Time.at(Rational(Integer("#{m[1]}#{m[2]}", 16), 1000)).utc.to_date
      end

      # The day whose file a log goes in: the day its log_id was minted, or
      # today for one that isn't a UUIDv7.
      def ingest_day(log_id) = day_for(log_id) || today

      def today = Time.now.utc.to_date

      # Runs the block against the day's file, creating it first if this is the
      # day's first write.
      def write(day, &)
        create(day) unless path_for(day).file?
        register(shard_for(day)).with(&)
      end

      # Removes a day's file. Its pool is dropped here, and other processes
      # drop theirs the next time they list shards (see prune!) — unless a
      # connection is in use: a read already under way keeps reading the
      # deleted file, which on Linux stays whole until it's closed.
      #
      # The database goes before its -wal and -shm, so nothing can open it in
      # between and leave those behind.
      def delete!(shard)
        unregister(shard.name, unless_in_use: true)
        FileUtils.rm_f(shard.path)
        %w[-wal -shm].each { |suffix| FileUtils.rm_f("#{shard.path}#{suffix}") }
        bounds_cache.delete(shard.name)
      end

      # [oldest, newest] timestamp, or nil for an empty file. Two index seeks,
      # not one MIN/MAX statement, which SQLite would answer with a full scan
      # (see StorageStats.data_span). A closed file's bounds don't change, so
      # they're kept until the file goes; an open one's are read each time.
      def bounds(shard)
        read = -> { shard.with { (oldest = Log.unscoped.minimum(:timestamp)) && [oldest, Log.unscoped.maximum(:timestamp)] } }
        shard.closed? ? bounds_cache.fetch_or_store(shard.name) { read.call } : read.call
      end

      private

      # Whether the legacy path holds a logs database. A file there without a
      # logs table — the empty one SQLite makes when something opens a missing
      # path, or the FTS-only stub the old boot initializer left on installs
      # that never took a log — is passed over rather than failing every read.
      # Asked once, and again when legacy_path changes: a file doesn't turn
      # into a logs database later.
      def legacy_logs?
        path = legacy_path
        return false unless path&.file?
        return @legacy_logs unless @legacy_logs.nil?

        db = SQLite3::Database.new(path.to_s, flags: SQLite3::Constants::Open::READONLY)
        @legacy_logs = !db.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'logs'").nil?
      ensure
        db&.close
      end

      def catalog_config
        LogsRecord.configurations.configs_for(env_name: Rails.env, name: "logs").configuration_hash
      end

      def shard_for(day) = Shard.new(name: :"#{SHARD_PREFIX}#{day.strftime("%Y%m%d")}", day: day, path: path_for(day))

      attr_reader :registered

      attr_reader :bounds_cache

      attr_reader :mutex

      # Both roles, as connects_to gives the default shard, so a caller that
      # switches to :reading still finds the file. Pools connect lazily.
      #
      # Opened without SQLITE_OPEN_CREATE: only create makes a day file, so a
      # connection to one retention has since deleted fails rather than
      # leaving an empty file in its place.
      def register(shard)
        return shard if registered[shard.name] == shard.path.to_s

        mutex.synchronize do
          next if registered[shard.name] == shard.path.to_s

          config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
            Rails.env, shard.name.to_s,
            catalog_config.except(:day_files, :legacy_database, :migrations_paths)
              .merge(database: shard.path.to_s, flags: SQLite3::Constants::Open::READWRITE)
          )
          %i[writing reading].each do |role|
            ActiveRecord::Base.connection_handler.establish_connection(config, owner_name: LogsRecord, role: role, shard: shard.name)
          end
          registered[shard.name] = shard.path.to_s
        end
        shard
      end

      # Drops a shard's pools. With unless_in_use, leaves them while another
      # thread has a connection checked out, and says so: Rails' disconnect
      # waits out the checkout timeout, twice, for it to come back, then closes
      # it under whoever has it. Left registered, the shard is tried again by
      # the next prune!, and meanwhile the pool's reaper closes its idle
      # connections.
      #
      # This thread's own lease is handed back first. Job threads run with no
      # executor to return leases between jobs, so one left by an earlier job
      # would otherwise keep a deleted file open for as long as the worker runs.
      # (A connection a test has pinned isn't released by this, and so stays.)
      # That release would also take back a connection this thread is using
      # inside with_connection on the same pool, so don't call this, or shards,
      # from inside a shard's block. Nothing does: prune! only reaches files
      # already deleted.
      def unregister(name, unless_in_use: false)
        mutex.synchronize do
          handler = ActiveRecord::Base.connection_handler
          roles = %i[writing reading]
          if unless_in_use
            pools = roles.filter_map { |role| handler.retrieve_connection_pool("LogsRecord", role: role, shard: name) }
            pools.each(&:release_connection)
            next false if pools.any? { |pool| pool.connections.any?(&:in_use?) }
          end
          roles.each { |role| handler.remove_connection_pool("LogsRecord", role: role, shard: name) }
          registered.delete(name)
          true
        end
      end

      def prune!
        registered.each_pair { |name, path| unregister(name, unless_in_use: true) unless File.exist?(path) }
      end

      # Built beside the target and renamed into place, so another process
      # sees either no file or a whole one, never a half-made schema. The lock
      # makes the rename safe: whoever takes it second finds the file there
      # and leaves it. (A hard link would do without the lock, but some
      # filesystems, Docker Desktop bind mounts among them, have none.) Not
      # through Active Record: a test's fixture transaction would roll the
      # schema back.
      def create(day)
        path = path_for(day)
        FileUtils.mkdir_p(root)
        File.open(root.join(".create.lock"), File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          next if path.file?

          tmp = "#{path}.#{SecureRandom.hex(4)}.tmp"
          db = SQLite3::Database.new(tmp)
          db.execute("PRAGMA journal_mode = wal")
          db.execute_batch(SCHEMA)
          db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
          db.close
          File.rename(tmp, path)
        ensure
          db&.close unless db&.closed?
          ["", "-wal", "-shm"].each { |suffix| FileUtils.rm_f("#{tmp}#{suffix}") } if tmp
        end
      end
    end
  end
end

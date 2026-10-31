ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Logs live in day files (Logs::DayFiles) under tmp/storage/test_logs, one
# directory per parallel worker. A test's rows roll back with its transaction,
# but the files stay, so each run starts from empty directories.
LOGS_DAY_FILES_ROOT = Logs::DayFiles.root
FileUtils.rm_rf(LOGS_DAY_FILES_ROOT)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    parallelize_setup do |worker|
      Logs::DayFiles.root = "#{LOGS_DAY_FILES_ROOT}-#{worker}"
      FileUtils.rm_rf(Logs::DayFiles.root)
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # The facet write throttles remember a key per process, and a rolled-back
    # test frees its ids for the next one: a later test's issue 3 harvesting
    # "id:1" was skipped as already written by an earlier test's issue 3.
    setup do
      Facet.reset_throttle!
      IssueFacet.reset_throttle!
    end

    # A test's rows roll back with its transaction, but the day files they
    # went into stay, and a file one test leaves is one a later test's
    # retention run deletes from under a connection its fixtures have pinned.
    # So every test ends with none — after the fixtures' own teardown, once
    # nothing holds them.
    def after_teardown
      super
      Logs::DayFiles.shards.each { Logs::DayFiles.delete!(it) unless it.legacy? }
    end

    # A logs database as it was before day files (ADR 0005): attrs_text and
    # updated_at columns, an external-content logs_fts kept by triggers, its own
    # compression dictionaries. Rows are hashes of column values.
    def build_legacy_logs(path, rows: [], dictionaries: [])
      db = SQLite3::Database.new(path.to_s)
      db.execute_batch(<<~SQL)
        CREATE TABLE logs ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "project_id" integer NOT NULL,
          "log_id" varchar, "timestamp" datetime(6) NOT NULL, "level" integer, "severity_number" integer,
          "body" text, "logger_name" varchar, "trace_id" varchar, "span_id" varchar, "environment" varchar,
          "release" varchar, "server_name" varchar, "source" varchar, "payload_blob" blob, "dict_id" bigint,
          "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, "attrs_text" text,
          "service" varchar, "duration_ms" float);
        CREATE INDEX index_logs_on_timestamp ON logs (timestamp);
        CREATE INDEX index_logs_on_log_id ON logs (log_id);
        CREATE INDEX index_logs_on_trace_id ON logs (trace_id);
        CREATE VIRTUAL TABLE logs_fts USING fts5(body, attrs_text, content='logs', content_rowid='id');
        CREATE TRIGGER logs_fts_ai AFTER INSERT ON logs BEGIN
          INSERT INTO logs_fts(rowid, body, attrs_text) VALUES (new.id, new.body, new.attrs_text);
        END;
        CREATE TABLE compression_dictionaries ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
          "segment" varchar NOT NULL, "version" integer NOT NULL, "dict" blob NOT NULL,
          "trained_at" datetime(6) NOT NULL, "sample_count" integer, "baseline_ratio" float,
          "active" boolean DEFAULT FALSE NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
        CREATE TABLE dictionary_training_runs ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL,
          "segment" varchar NOT NULL, "ran_at" datetime(6) NOT NULL, "samples" integer, "current_ratio" float,
          "candidate_ratio" float, "gain" float, "promoted" boolean DEFAULT FALSE NOT NULL,
          "promoted_to_version" integer, "notes" text);
      SQL
      stamp = ->(t) { t.utc.strftime("%Y-%m-%d %H:%M:%S.%6N") }
      rows.each do |row|
        row = {log_id: SecureRandom.uuid_v7, level: 2, source: "sentry", created_at: row[:timestamp]}.merge(row)
        row[:updated_at] ||= row[:created_at]
        row = row.transform_values { |v| v.respond_to?(:utc) ? stamp.call(v) : v }
        db.execute("INSERT INTO logs (#{row.keys.join(", ")}) VALUES (#{(["?"] * row.size).join(", ")})", row.values)
      end
      dictionaries.each do |dict|
        now = stamp.call(Time.current)
        db.execute("INSERT INTO compression_dictionaries (id, segment, version, dict, trained_at, active, created_at, updated_at) " \
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [dict[:id], dict[:segment], dict[:version], SQLite3::Blob.new(dict[:dict]), now, dict[:active] ? 1 : 0, now, now])
      end
      path
    ensure
      db&.close
    end

    # A UUIDv7 minted at `time`, so a log lands in that day's file: ingest
    # files a log under the day its log_id was minted.
    def log_id_at(time)
      hex = (time.to_r * 1000).to_i.to_s(16).rjust(12, "0") + SecureRandom.hex(10)
      "#{hex[0, 8]}-#{hex[8, 4]}-7#{hex[13, 3]}-#{%w[8 9 a b].sample}#{hex[17, 3]}-#{hex[20, 12]}"
    end

    # Jobs spooled while tuber is down go to a directory of the test's own, so
    # parallel workers never replay each other's.
    setup { Ingest::Spool.dir = Dir.mktmpdir("spool") }
    teardown do
      FileUtils.rm_rf(Ingest::Spool.dir)
      Ingest::Spool.dir = nil
      Ingest::Spool.max_bytes = nil
    end

    # Temporarily replace a singleton (class) method, restoring the *real* one
    # afterward. Minitest 6 dropped #stub, and the obvious
    # `singleton_class.define_method` + `remove_method` dance deletes the
    # original method for the rest of the worker process — which silently broke
    # whichever test ran next in the same parallel worker (e.g. "undefined
    # method 'put' for Ingest::Tuber"). Capturing and re-installing the original
    # Method object avoids that.
    def with_stub(owner, name, replacement)
      original = owner.method(name)
      owner.singleton_class.define_method(name, replacement)
      yield
    ensure
      owner.singleton_class.define_method(name, original)
    end

    # Sentry as production runs it, tracing every request, for the length of
    # the block. sentry-rails puts its around_action on controllers only when
    # Sentry is up at boot, which it never is in tests, so it goes on the
    # controllers given here; it does nothing once Sentry is closed again.
    def with_sentry_tracing(*controllers)
      require "sentry/rails/controller_transaction"
      controllers.each { it.include(Sentry::Rails::ControllerTransaction) unless it < Sentry::Rails::ControllerTransaction }
      Sentry.init do |config|
        config.dsn = "http://12345:67890@sentry.localdomain/sentry/42"
        config.transport.transport_class = Sentry::DummyTransport
        config.background_worker_threads = 0
        config.traces_sample_rate = 1.0
      end
      yield
    ensure
      Sentry.close if Sentry.initialized?
    end

    # A request body in one of the Content-Encodings ingest reads.
    def compress(encoding, text)
      compressed(encoding) { |write| write.call(text) }
    end

    # bytes of zeros, compressed a megabyte at a time: a body that's small as
    # sent and enormous once decompressed, built without holding it all.
    def compressed_zeros(encoding, bytes)
      megabyte = "\0" * 1.megabyte
      compressed(encoding) { |write| (bytes / megabyte.bytesize).times { write.call(megabyte) } }
    end

    def compressed(encoding)
      io = StringIO.new(+"".b)
      case encoding
      when "gzip"
        gz = Zlib::GzipWriter.new(io)
        yield ->(data) { gz.write(data) }
        gz.finish
      when "deflate"
        zd = Zlib::Deflate.new
        yield ->(data) { io.write(zd.deflate(data)) }
        io.write(zd.finish)
      when "br"
        br = Brotli::Writer.new(io, quality: 1)
        yield ->(data) { br.write(data) }
        br.finish
      when "zstd"
        zs = Zstd::StreamingCompress.new
        yield ->(data) { io.write(zs.compress(data)) }
        io.write(zs.finish)
      end
      io.string
    end
  end
end

# frozen_string_literal: true

# ADR 0005 experiment: build one day of production logs in each candidate
# layout, then measure size and query cost on the same machine.
#
#   bin/rails runner script/logs_blocks_experiment.rb storage/experiments/logs_2026-10-27.sqlite3
#
# Input is a day file from script/logs_day_export.rb. Output goes beside it, in
# <name>_arms/: one SQLite file per arm, report.md and results.json. Nothing
# touches the app's own databases. The app is loaded for Log.fts_query,
# Logs::Uuid, Logs::AttrsText and Logs::AttributeValue, so queries and
# tokenising match production.
#
# Arms
#   A   today's layout, built fresh: rows with body, attrs_text and
#       payload_blob, the 11 production indexes, and the external-content FTS5
#       (rebuilt, then optimized). Set beside production's own bytes per log,
#       the gap is what retention churn costs.
#   B   one file per day: today's rows without body and attrs_text, the same
#       indexes, and a contentless FTS5. Retention would delete files, so there
#       are no delete markers, merges or vacuums.
#   C   blocks: one row per block of up to LOGS_BLOCK_ROWS logs from one stream
#       (project, environment, service), with header summaries, a bloom filter
#       and a zstd body. The same blocks in two encodings:
#         C1  rows packed with msgpack, one zstd frame per block
#         C2  one zstd frame per column, with a column per attribute key
#       C1 also gets a (trace_id, block_id) side table, sized separately.
#
# Decision rule, fixed before the first production run:
#   * Blocks go ahead only if the better of C1 and C2 is at most a third of B's
#     bytes per log. Between a third and a half, the query costs below decide.
#     Above a half, ship B.
#   * Query bars, per day of data, warm cache: newest 50 and level:error under
#     100 ms; a rare term, a trace lookup and a log_id lookup under 1 s, so 15
#     days stay inside the 15 s MCP cap. A C query over its bar means the scan
#     needs Rust, which counts against blocks.
#
# Settings (ENV):
#   LOGS_ARMS           arms to build and query, default "a,b,c" (b always builds)
#   LOGS_BLOCK_ROWS     logs per block, default 1000
#   LOGS_ZSTD_LEVEL     zstd level for blocks, default 3 (payload_blob's level)
#   LOGS_BLOOM_BITS     bloom bits per distinct token, default 12
#   LOGS_BLOOM_K        bloom hash count, default 6
#   LOGS_FLUSH_SECONDS  flush interval for the pre-compaction layout, default 60
#   LOGS_WARM_RUNS      warm runs per query (median reported), default 5
#   LOGS_COLD_RUNS      cold runs per query, page cache evicted first, default 2
#   LOGS_SEED           seed for picking query terms, default 1

require "fileutils"
require "json"
require "msgpack"
require "zlib"
require "zstd-ruby"

module LogsBlocksExperiment
  BLOCK_ROWS = Integer(ENV.fetch("LOGS_BLOCK_ROWS", "1000"))
  ZSTD_LEVEL = Integer(ENV.fetch("LOGS_ZSTD_LEVEL", "3"))
  BLOOM_BITS = Integer(ENV.fetch("LOGS_BLOOM_BITS", "12"))
  BLOOM_K = Integer(ENV.fetch("LOGS_BLOOM_K", "6"))
  FLUSH_SECONDS = Integer(ENV.fetch("LOGS_FLUSH_SECONDS", "60"))
  WARM_RUNS = Integer(ENV.fetch("LOGS_WARM_RUNS", "5"))
  COLD_RUNS = Integer(ENV.fetch("LOGS_COLD_RUNS", "2"))
  ARMS = (ENV.fetch("LOGS_ARMS", "a,b,c").split(",").map(&:strip) | ["b"]).freeze
  LIMIT = 50
  HOUR_US = 3_600_000_000
  ABSENT_TERM = "zqxjkvbwpf"

  # Production's index set (db/logs_schema.rb).
  INDEXES = [
    "CREATE INDEX index_logs_on_environment_and_timestamp ON logs (environment, timestamp)",
    "CREATE INDEX index_logs_on_level_and_timestamp ON logs (level, timestamp)",
    "CREATE INDEX index_logs_on_log_id ON logs (log_id)",
    "CREATE INDEX index_logs_on_project_id_and_duration_ms ON logs (project_id, duration_ms) WHERE duration_ms IS NOT NULL",
    "CREATE INDEX index_logs_on_project_id_and_environment ON logs (project_id, environment)",
    "CREATE INDEX index_logs_on_project_id_and_release_and_timestamp ON logs (project_id, release, timestamp)",
    "CREATE INDEX index_logs_on_project_id_and_service ON logs (project_id, service) WHERE service IS NOT NULL",
    "CREATE INDEX index_logs_on_project_id_and_timestamp ON logs (project_id, timestamp)",
    "CREATE INDEX index_logs_on_project_id_and_trace_id_and_timestamp ON logs (project_id, trace_id, timestamp)",
    "CREATE INDEX index_logs_on_timestamp ON logs (timestamp)",
    "CREATE INDEX index_logs_on_trace_id ON logs (trace_id)"
  ].freeze

  B_COLUMNS = %w[id project_id log_id timestamp level severity_number logger_name trace_id span_id
    environment release server_name service source duration_ms payload_blob dict_id created_at].freeze

  BLOCKS_SQL = <<~SQL
    CREATE TABLE blocks (
      id INTEGER PRIMARY KEY,
      project_id INTEGER NOT NULL,
      environment TEXT,
      service TEXT,
      min_ts INTEGER NOT NULL,
      max_ts INTEGER NOT NULL,
      row_count INTEGER NOT NULL,
      level_mask INTEGER NOT NULL,
      max_duration REAL,
      summary BLOB,
      bloom BLOB NOT NULL,
      data BLOB NOT NULL
    )
  SQL

  Rec = Struct.new(:ts, :level, :severity_number, :body, :logger_name, :trace_id, :span_id,
    :release, :server_name, :source, :duration_ms, :log_id, :payload)
  REC_INDEX = Rec.members.each_with_index.to_h.freeze

  module_function

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def median(values) = values.empty? ? nil : values.sort[values.size / 2]

  # "2026-10-27 12:34:56.123456" (how Rails stores datetimes in SQLite) to
  # microseconds since the epoch.
  def ts_us(str)
    t = Time.utc(str[0, 4].to_i, str[5, 2].to_i, str[8, 2].to_i, str[11, 2].to_i, str[14, 2].to_i, str[17, 2].to_i)
    frac = str[20, 6].to_s
    t.to_i * 1_000_000 + (frac.empty? ? 0 : frac.ljust(6, "0").to_i)
  end

  def new_db(path)
    FileUtils.rm_f(path)
    db = SQLite3::Database.new(path)
    db.execute("PRAGMA journal_mode = OFF")
    db.execute("PRAGMA synchronous = OFF")
    db.execute("PRAGMA cache_size = -262144")
    db
  end

  # Bytes per b-tree, from dbstat, grouped by what the b-tree is for.
  def btree_bytes(path)
    db = SQLite3::Database.new(path, readonly: true)
    rows = db.execute("SELECT name, SUM(pgsize) FROM dbstat GROUP BY name")
    db.close
    rows.each_with_object(Hash.new(0)) do |(name, bytes), h|
      group = case name
      when /\Aindex_logs_/ then "indexes"
      when /\Alogs_fts_/ then "fts"
      when /\A(fts_[a-z]+)_(data|idx|docsize|config)\z/ then $1
      when "logs" then "rows"
      when "blocks", "block_traces" then name
      else "other"
      end
      h[group] += bytes
    end
  end

  # The export file. Read-only.
  class Source
    REC_COLUMNS = %w[id timestamp level severity_number body logger_name trace_id span_id release
      server_name source duration_ms log_id payload_blob dict_id].freeze

    attr_reader :path, :db, :meta

    def initialize(path)
      @path = path
      @db = SQLite3::Database.new(path, readonly: true)
      @meta = @db.execute("SELECT key, value FROM export_meta").to_h
      @ddicts = @db.execute("SELECT id, dict FROM compression_dictionaries").to_h { |id, d| [id, Zstd::DDict.new(d)] }
    end

    def rows = @rows ||= @db.get_first_value("SELECT COUNT(*) FROM logs")

    def create_sql(table) = @db.get_first_value("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])

    def payload(blob, dict_id)
      JSON.parse(dict_id ? Zstd.decompress(blob, dict: @ddicts.fetch(dict_id)) : Zstd.decompress(blob))
    end

    # Records for the given ids, oldest first, with the body taken out of the
    # payload (it is stored once, in the body field).
    def fetch_recs(ids)
      @db.execute("SELECT #{REC_COLUMNS.join(", ")} FROM logs WHERE id IN (#{ids.join(",")})").map do |row|
        _id, ts, level, sev, body, logger, trace, span, release, server, source, dur, log_id, blob, dict_id = row
        payload = payload(blob, dict_id)
        BodyStrip.strip!(payload, body)
        Rec.new(LogsBlocksExperiment.ts_us(ts), level, sev, body, logger, trace, span, release, server, source, dur, log_id, payload)
      end.sort_by! { |r| [r.ts, r.log_id.to_s] }
    end
  end

  # The body is a promoted field, so the copy inside the payload is dropped and
  # put back on read. A marker key says which shape it had.
  module BodyStrip
    MARK = "\u0000b"

    module_function

    def strip!(payload, body)
      b = payload["body"]
      if b.is_a?(String) && b == body
        payload.delete("body")
        payload[MARK] = 1
      elsif b.is_a?(Hash) && b.size == 1 && b["stringValue"] == body
        payload.delete("body")
        payload[MARK] = 2
      end
      payload
    end

    def restore(payload, body)
      payload = payload.dup
      case payload.delete(MARK)
      when 1 then payload["body"] = body
      when 2 then payload["body"] = {"stringValue" => body}
      end
      payload
    end
  end

  # What a block's bloom and the in-block match both see: words from the body,
  # words from attribute keys and values (with Logs::AttrsText's rules), and a
  # key=word token per word of each attribute value. trace_id and log_id go in
  # only as trace_id= and log_id= tokens, so a lookup by either is a bloom
  # check while a bare search matches what the FTS index matches.
  module Tokens
    WORD = /\p{Alnum}+/
    FLOAT = Logs::AttrsText::FLOAT_VALUE

    # OTLP resource attributes aren't in the stored payload; the parsers lift
    # these into promoted fields, so they come back from there.
    OTLP_ALIASES = {"service.name" => :service, "host.name" => :server_name,
                    "deployment.environment" => :environment, "service.version" => :release}.freeze

    module_function

    def words(text) = text.nil? ? [] : Logs::Uuid.collapse(text.to_s).downcase.scan(WORD)

    def attribute_pairs(payload)
      case (raw = payload["attributes"])
      when Array then raw.filter_map { |kv| [kv["key"], Logs::AttributeValue.unwrap(kv["value"])] if kv.is_a?(Hash) && kv["key"] }
      when Hash then raw.map { |k, v| [k, Logs::AttributeValue.unwrap(v)] }
      else []
      end
    end

    def promoted_pairs(source, fields)
      return [] unless source == "otlp"
      OTLP_ALIASES.filter_map { |key, field| [key, fields[field]] if fields[field] }
    end

    # [bare words, key=word tokens] for one log. ids is {"trace_id" => ..., "log_id" => ...}.
    def sets(body, pairs, ids)
      bare = Set.new(words(body))
      kv = Set.new
      pairs.each do |key, value|
        next if key.nil? || key.to_s.empty?
        k = key.to_s.downcase
        bare.merge(words(k))
        str = value.to_s
        next if value.nil? || str.empty? || str.match?(FLOAT)
        vw = words(Logs::AttrsText.truncate(str))
        bare.merge(vw)
        vw.each { |w| kv << "#{k}=#{w}" }
      end
      ids.each { |k, id| words(id).each { |w| kv << "#{k}=#{w}" } if id }
      [bare, kv]
    end
  end

  # A parsed search box, matched against the token sets above. Splits input
  # the way Log.fts_query does: bare words are ANDed, key:value matches words
  # of that attribute's value.
  class Query
    attr_reader :bare, :kv

    def initialize(text)
      @bare = []
      @kv = []
      Logs::Uuid.collapse(text.to_s).split(/\s+/).each do |term|
        if term.include?(":")
          key, val = term.split(":", 2)
          vw = Tokens.words(val)
          if vw.empty?
            @bare.concat(Tokens.words(key))
          else
            @kv.concat(vw.map { |w| "#{key.downcase}=#{w}" })
          end
        else
          @bare.concat(Tokens.words(term))
        end
      end
    end

    def empty? = @bare.empty? && @kv.empty?

    def bloom_tokens = @bare + @kv

    # Every word the query needs, for a substring check before tokenising.
    def needles = @needles ||= (@bare + @kv.map { |t| t.split("=", 2).last }).uniq

    # A word can only be a token of a row if it's a substring of the row's
    # text, lowercased with hyphens dropped (which keeps collapsed UUIDs whole).
    def maybe?(haystack) = needles.all? { |w| haystack.include?(w) }

    def match?(bare_set, kv_set) = @bare.all? { |w| bare_set.include?(w) } && @kv.all? { |t| kv_set.include?(t) }
  end

  # Bloom filter over a block's distinct tokens. Probes come from two CRC32s
  # (of the token and of it reversed): stable across processes, unlike
  # String#hash, and in C.
  module Bloom
    module_function

    def build(tokens)
      m = [(tokens.size * BLOOM_BITS + 7) / 8 * 8, 64].max
      bits = ("\0" * (m / 8)).b
      tokens.each do |t|
        h1 = Zlib.crc32(t)
        h2 = Zlib.crc32(t.reverse) | 1
        BLOOM_K.times do |i|
          p = (h1 + i * h2) % m
          bits.setbyte(p >> 3, bits.getbyte(p >> 3) | (1 << (p & 7)))
        end
      end
      bits
    end

    def include_all?(bits, tokens)
      m = bits.bytesize * 8
      tokens.all? do |t|
        h1 = Zlib.crc32(t)
        h2 = Zlib.crc32(t.reverse) | 1
        BLOOM_K.times.all? do |i|
          p = (h1 + i * h2) % m
          bits.getbyte(p >> 3) & (1 << (p & 7)) != 0
        end
      end
    end
  end

  # C1: the block's records as msgpack arrays, one zstd frame.
  class RowsBlock
    def self.encode(recs) = Zstd.compress(MessagePack.pack(recs.map(&:to_a)), level: ZSTD_LEVEL)

    def initialize(data, _min_ts)
      @rows = MessagePack.unpack(Zstd.decompress(data))
      @cols = {}
    end

    def size = @rows.size

    def ts = column(:ts)

    def column(name)
      idx = REC_INDEX.fetch(name)
      @cols[name] ||= @rows.map { |r| r[idx] }
    end

    def attr_pairs(i) = Tokens.attribute_pairs(@rows[i][REC_INDEX[:payload]])

    def payload(i) = BodyStrip.restore(@rows[i][REC_INDEX[:payload]], @rows[i][REC_INDEX[:body]])

    def decode_all! = size
  end

  # C2: a zstd frame per column. Timestamps are deltas; each attribute key gets
  # a value column ("a:") and a type column ("t:"), other payload keys one
  # column each ("p:"). Key order inside attributes isn't kept.
  class ColsBlock
    FIELDS = (Rec.members - %i[ts payload]).freeze

    def self.encode(recs)
      n = recs.size
      cols = {}
      col = ->(name) { cols[name] ||= Array.new(n) }
      prev = recs.first.ts
      cols["ts"] = recs.map { |r|
        d = r.ts - prev
        prev = r.ts
        d
      }
      FIELDS.each { |f| cols[f.to_s] = recs.map(&f) }
      recs.each_with_index do |r, i|
        r.payload.each do |key, value|
          if key == "attributes" && value.is_a?(Hash)
            col.call("p:attributes")[i] = "h"
            value.each do |ak, av|
              if av.is_a?(Hash) && av.key?("value")
                col.call("a:#{ak}")[i] = av["value"]
                col.call("t:#{ak}")[i] = av.except("value")
              else
                col.call("x:#{ak}")[i] = av
              end
            end
          elsif key == "attributes" && value.is_a?(Array)
            col.call("p:attributes")[i] = "a"
            value.each do |kv|
              next unless kv.is_a?(Hash) && kv["key"]
              if kv["value"].is_a?(Hash) && kv["value"].size == 1
                type, v = kv["value"].first
                col.call("a:#{kv["key"]}")[i] = v
                col.call("t:#{kv["key"]}")[i] = type
              else
                col.call("x:#{kv["key"]}")[i] = kv["value"]
              end
            end
          else
            col.call("p:#{key}")[i] = value
          end
        end
      end
      MessagePack.pack(cols.transform_values { |values| Zstd.compress(MessagePack.pack(values), level: ZSTD_LEVEL) })
    end

    def initialize(data, min_ts)
      @frames = MessagePack.unpack(data)
      @min_ts = min_ts
      @cache = {}
    end

    def frame(name) = @cache[name] ||= (f = @frames[name]) ? MessagePack.unpack(Zstd.decompress(f)) : nil

    def size = ts.size

    def ts
      @ts ||= begin
        acc = @min_ts
        frame("ts").map { |d| acc += d }
      end
    end

    def column(name) = (name == :ts) ? ts : frame(name.to_s)

    def attr_pairs(i)
      @attr_cols ||= @frames.keys.filter_map do |k|
        if k.start_with?("a:") then [k.delete_prefix("a:"), frame(k), false]
        elsif k.start_with?("x:") then [k.delete_prefix("x:"), frame(k), true]
        end
      end
      @attr_cols.filter_map do |key, values, wrapped|
        v = values[i]
        [key, wrapped ? Logs::AttributeValue.unwrap(v) : v] unless v.nil?
      end
    end

    def decode_all!
      @frames.each_key { |k| frame(k) }
      size
    end
  end

  class BlockWriter
    attr_reader :path, :data_bytes, :bloom_bytes, :blocks

    def initialize(path, kind, side_table: false)
      @path = path
      @kind = kind
      @db = LogsBlocksExperiment.new_db(path)
      @db.execute(BLOCKS_SQL)
      @db.execute("CREATE INDEX blocks_by_project_max_ts ON blocks (project_id, max_ts)")
      @side_table = side_table
      @db.execute("CREATE TABLE block_traces (trace_id TEXT NOT NULL, block_id INTEGER NOT NULL, PRIMARY KEY (trace_id, block_id)) WITHOUT ROWID") if side_table
      @insert = @db.prepare("INSERT INTO blocks (project_id, environment, service, min_ts, max_ts, row_count, level_mask, max_duration, summary, bloom, data) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
      @trace_insert = @db.prepare("INSERT OR IGNORE INTO block_traces (trace_id, block_id) VALUES (?, ?)") if side_table
      @data_bytes = 0
      @bloom_bytes = 0
      @blocks = 0
      @db.execute("BEGIN")
    end

    def encode(recs) = ((@kind == :rows) ? RowsBlock : ColsBlock).encode(recs)

    def write(stream, recs, bloom, data)
      project_id, environment, service = stream
      level_mask = recs.reduce(0) { |m, r| r.level ? m | (1 << r.level) : m }
      max_duration = recs.filter_map(&:duration_ms).max
      summary = MessagePack.pack(%i[release server_name source logger_name].to_h do |f|
        distinct = recs.map(&f).uniq
        [f.to_s, (distinct.size <= 32) ? distinct : nil]
      end)
      @insert.execute(project_id, environment, service, recs.first.ts, recs.last.ts, recs.size, level_mask,
        max_duration, SQLite3::Blob.new(summary), SQLite3::Blob.new(bloom), SQLite3::Blob.new(data))
      if @side_table
        block_id = @db.last_insert_row_id
        recs.filter_map(&:trace_id).uniq.each { |t| @trace_insert.execute(t.downcase, block_id) }
      end
      @data_bytes += data.bytesize
      @bloom_bytes += bloom.bytesize
      @blocks += 1
    end

    def close
      @db.execute("COMMIT")
      @insert.close
      @trace_insert&.close
      @db.close
    end
  end

  # Today's shape, for arms A and B.
  class SqlArm
    attr_reader :path

    def initialize(path, kind, source)
      @path = path
      @kind = kind
      @source = source
    end

    def open! = @db = SQLite3::Database.new(@path, readonly: true)

    def close!
      @db&.close
      @db = nil
    end

    def body_columns = (@kind == :a) ? "body" : "payload_blob, dict_id"

    def body_of(row) = (@kind == :a) ? row[0] : Logs::AttributeValue.unwrap(@source.payload(row[0], row[1])["body"]).to_s

    def listed(sql, binds)
      rows = @db.execute("SELECT log_id, timestamp, level, #{body_columns} FROM logs WHERE #{sql}", binds)
      rows.each { |r| body_of(r[3..]) }
      {ids: rows.map(&:first)}
    end

    def newest(project_id, offset: 0, level: nil, text: nil, min_duration: nil)
      where = ["project_id = ?"]
      binds = [project_id]
      if level
        where << "level = ?"
        binds << level
      end
      if min_duration
        where << "duration_ms >= ?"
        binds << min_duration
      end
      if text && (match = Log.fts_query(text))
        where << "id IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)"
        binds << match
      end
      listed("#{where.join(" AND ")} ORDER BY timestamp DESC LIMIT #{LIMIT} OFFSET #{offset}", binds)
    end

    def trace(trace_id, via: nil) = listed("trace_id = ? ORDER BY timestamp", [trace_id])

    def by_log_id(log_id) = listed("log_id = ?", [log_id])

    def timeline(project_id)
      {buckets: @db.execute("SELECT substr(timestamp, 1, 13), COUNT(*) FROM logs WHERE project_id = ? GROUP BY 1", [project_id]).size}
    end
  end

  # Blocks, for C1 and C2: header scan newest first, skip on level mask,
  # duration and bloom, decode what's left and match row by row.
  class BlockArm
    attr_reader :path

    def initialize(path, kind)
      @path = path
      @kind = kind
    end

    def open! = @db = SQLite3::Database.new(@path, readonly: true)

    def close!
      @db&.close
      @db = nil
    end

    def side_table? = @kind == :rows

    def block(id, min_ts) = ((@kind == :rows) ? RowsBlock : ColsBlock).new(@db.get_first_value("SELECT data FROM blocks WHERE id = ?", [id]), min_ts)

    def row_pairs(blk, i, environment, service)
      fields = {service: service, environment: environment,
                server_name: blk.column(:server_name)[i], release: blk.column(:release)[i]}
      blk.attr_pairs(i) + Tokens.promoted_pairs(blk.column(:source)[i], fields)
    end

    def row_matches?(query, blk, i, environment, service)
      pairs = row_pairs(blk, i, environment, service)
      body = blk.column(:body)[i]
      trace_id = blk.column(:trace_id)[i]
      log_id = blk.column(:log_id)[i]
      haystack = [body, trace_id, log_id, *pairs.flatten].join(" ").downcase.delete("-")
      query.maybe?(haystack) && query.match?(*Tokens.sets(body, pairs, {"trace_id" => trace_id, "log_id" => log_id}))
    end

    def newest(project_id, offset: 0, level: nil, text: nil, min_duration: nil)
      want = offset + LIMIT
      query = text && Query.new(text)
      query = nil if query && query.empty?
      hits = []
      read = 0
      checked = 0
      sql = "SELECT id, min_ts, max_ts, level_mask, max_duration, environment, service#{", bloom" if query} " \
            "FROM blocks WHERE project_id = ? ORDER BY max_ts DESC"
      @db.execute(sql, [project_id]) do |id, min_ts, max_ts, mask, max_dur, environment, service, bloom|
        break if hits.size >= want && max_ts < hits[want - 1][0]
        checked += 1
        next if level && mask & (1 << level) == 0
        next if min_duration && (max_dur.nil? || max_dur < min_duration)
        next if query && !Bloom.include_all?(bloom, query.bloom_tokens)

        blk = block(id, min_ts)
        read += 1
        ts = blk.ts
        levels = level && blk.column(:level)
        durations = min_duration && blk.column(:duration_ms)
        (blk.size - 1).downto(0) do |i|
          next if levels && levels[i] != level
          next if durations && (durations[i].nil? || durations[i] < min_duration)
          next if query && !row_matches?(query, blk, i, environment, service)
          hits << [ts[i], blk, i]
        end
        hits = hits.sort_by { |h| -h[0] }.first(want)
      end
      page = hits[offset, LIMIT] || []
      page.each { |_, blk, i| blk.column(:body)[i] }
      {ids: page.map { |_, blk, i| blk.column(:log_id)[i] }, blocks_checked: checked, blocks_read: read}
    end

    # Every log of a trace, oldest first, over the whole file: by bloom, or by
    # the side table when there is one.
    def trace(trace_id, via: :bloom)
      token = "trace_id=#{trace_id.downcase}"
      candidates =
        if via == :side
          @db.execute("SELECT b.id, b.min_ts FROM block_traces t JOIN blocks b ON b.id = t.block_id WHERE t.trace_id = ?", [trace_id.downcase])
        else
          @db.execute("SELECT id, min_ts, bloom FROM blocks").select { |_, _, bloom| Bloom.include_all?(bloom, [token]) }
        end
      collect(candidates) { |blk, i| blk.column(:trace_id)[i] == trace_id }
    end

    def by_log_id(log_id)
      token = "log_id=#{Tokens.words(log_id).first}"
      candidates = @db.execute("SELECT id, min_ts, bloom FROM blocks").select { |_, _, bloom| Bloom.include_all?(bloom, [token]) }
      collect(candidates) { |blk, i| blk.column(:log_id)[i] == log_id }
    end

    def collect(candidates)
      hits = []
      candidates.each do |id, min_ts, _|
        blk = block(id, min_ts)
        blk.size.times { |i| hits << [blk.ts[i], blk.column(:log_id)[i], blk.column(:body)[i]] if yield(blk, i) }
      end
      {ids: hits.sort_by(&:first).map { |h| h[1] }, blocks_read: candidates.size}
    end

    # Hourly counts. A block inside one hour counts from its header; others
    # decode their timestamps.
    def timeline(project_id)
      counts = Hash.new(0)
      read = 0
      @db.execute("SELECT id, min_ts, max_ts, row_count FROM blocks WHERE project_id = ?", [project_id]) do |id, min_ts, max_ts, n|
        if min_ts / HOUR_US == max_ts / HOUR_US
          counts[min_ts / HOUR_US] += n
        else
          read += 1
          block(id, min_ts).ts.each { |t| counts[t / HOUR_US] += 1 }
        end
      end
      {buckets: counts.size, blocks_read: read}
    end

    def full_scan
      rows = 0
      @db.execute("SELECT id, min_ts FROM blocks") { |id, min_ts| rows += block(id, min_ts).decode_all! }
      {rows: rows}
    end
  end

  class Run
    def initialize(src_path)
      @src = Source.new(src_path)
      @dir = File.join(File.dirname(src_path), "#{File.basename(src_path, ".sqlite3")}_arms")
      FileUtils.mkdir_p(@dir)
      @results = {"export" => @src.meta, "settings" => settings, "sizes" => {}, "builds" => {}, "queries" => {}}
      $stdout.sync = true
    end

    def settings
      {"block_rows" => BLOCK_ROWS, "zstd_level" => ZSTD_LEVEL, "bloom_bits" => BLOOM_BITS, "bloom_k" => BLOOM_K,
       "flush_seconds" => FLUSH_SECONDS, "warm_runs" => WARM_RUNS, "cold_runs" => COLD_RUNS, "arms" => ARMS}
    end

    def file(name) = File.join(@dir, name)

    def step(label)
      print "#{label} ... "
      t0 = LogsBlocksExperiment.now
      out = yield
      secs = LogsBlocksExperiment.now - t0
      puts format("%.1fs", secs)
      @results["builds"][label] = secs.round(2)
      out
    end

    def call
      puts "Export #{@src.meta["day"]}: #{@src.rows} logs"
      lateness
      build_a if ARMS.include?("a")
      build_b
      build_fts_variants
      build_c if ARMS.include?("c")
      sealed_c if ARMS.include?("c")
      run_queries
      File.write(file("results.json"), JSON.pretty_generate(@results))
      report = Report.new(@results, @src.rows).to_s
      File.write(file("report.md"), report)
      puts "\n#{report}\nWrote #{file("report.md")} and #{file("results.json")}"
    end

    # How late logs arrive, by created_at (ingest) against timestamp: decides
    # whether a day file can be closed at midnight.
    def lateness
      lags = []
      crossed = 0
      @src.db.execute("SELECT timestamp, created_at FROM logs") do |ts, created|
        lag = (LogsBlocksExperiment.ts_us(created) - LogsBlocksExperiment.ts_us(ts)) / 1e6
        lags << lag
        crossed += 1 if created[0, 10] != ts[0, 10]
      end
      lags.sort!
      pct = ->(p) { lags[[(lags.size * p).floor, lags.size - 1].min].round(1) }
      @results["lateness"] = {
        "p50_s" => pct.call(0.5), "p99_s" => pct.call(0.99), "p999_s" => pct.call(0.999), "max_s" => lags.last.round(1),
        "min_s" => lags.first.round(1), "over_60s" => lags.count { |l| l > 60 }, "over_1h" => lags.count { |l| l > 3600 },
        "ingested_another_day" => crossed
      }
    end

    def build_a
      path = file("a.sqlite3")
      step("A: build") do
        db = LogsBlocksExperiment.new_db(path)
        db.execute(@src.create_sql("logs"))
        db.execute("ATTACH ? AS src", [@src.path])
        db.execute("INSERT INTO logs SELECT * FROM src.logs ORDER BY id")
        db.execute("DETACH src")
        INDEXES.each { |sql| db.execute(sql) }
        db.execute("CREATE VIRTUAL TABLE logs_fts USING fts5(body, attrs_text, content='logs', content_rowid='id')")
        db.execute("INSERT INTO logs_fts(logs_fts) VALUES('rebuild')")
        db.execute("INSERT INTO logs_fts(logs_fts) VALUES('optimize')")
        db.execute("VACUUM")
        db.close
      end
      record_size("A", path)
    end

    def build_b
      path = file("b.sqlite3")
      step("B: build") do
        db = LogsBlocksExperiment.new_db(path)
        db.execute(<<~SQL)
          CREATE TABLE logs (
            id INTEGER PRIMARY KEY, project_id INTEGER NOT NULL, log_id TEXT, timestamp TEXT NOT NULL,
            level INTEGER, severity_number INTEGER, logger_name TEXT, trace_id TEXT, span_id TEXT,
            environment TEXT, release TEXT, server_name TEXT, service TEXT, source TEXT,
            duration_ms REAL, payload_blob BLOB, dict_id INTEGER, created_at TEXT NOT NULL
          )
        SQL
        db.execute("ATTACH ? AS src", [@src.path])
        db.execute("INSERT INTO logs (#{B_COLUMNS.join(", ")}) SELECT #{B_COLUMNS.join(", ")} FROM src.logs ORDER BY id")
        INDEXES.each { |sql| db.execute(sql) }
        db.execute("CREATE VIRTUAL TABLE logs_fts USING fts5(body, attrs_text, content='')")
        db.execute("INSERT INTO logs_fts(rowid, body, attrs_text) SELECT id, body, attrs_text FROM src.logs ORDER BY id")
        db.execute("INSERT INTO logs_fts(logs_fts) VALUES('optimize')")
        db.execute("DETACH src")
        db.execute("VACUUM")
        db.close
      end
      record_size("B", path)
    end

    # The FTS alone with less detail stored: detail=column keeps which column
    # a word is in, detail=none only which rows. Neither supports phrases, so
    # key:value search would need key=value tokens instead.
    def build_fts_variants
      path = file("fts_variants.sqlite3")
      step("FTS variants: build") do
        db = LogsBlocksExperiment.new_db(path)
        db.execute("ATTACH ? AS src", [@src.path])
        %w[column none].each do |detail|
          db.execute("CREATE VIRTUAL TABLE fts_#{detail} USING fts5(body, attrs_text, content='', detail=#{detail})")
          db.execute("INSERT INTO fts_#{detail}(rowid, body, attrs_text) SELECT id, body, attrs_text FROM src.logs ORDER BY id")
          db.execute("INSERT INTO fts_#{detail}(fts_#{detail}) VALUES('optimize')")
        end
        db.execute("DETACH src")
        db.execute("VACUUM")
        db.close
      end
      @results["sizes"]["FTS variants"] = {"bytes" => File.size(path), "btrees" => LogsBlocksExperiment.btree_bytes(path)}
    end

    def record_size(arm, path)
      @results["sizes"][arm] = {"bytes" => File.size(path), "btrees" => LogsBlocksExperiment.btree_bytes(path)}
    end

    def streams
      streams = Hash.new { |h, k| h[k] = [] }
      @src.db.execute("SELECT id, project_id, environment, service, timestamp FROM logs") do |id, pid, env, svc, ts|
        streams[[pid, env, svc]] << [ts, id]
      end
      streams.each_value(&:sort!)
    end

    # The day after nightly compaction: each stream's logs in timestamp order,
    # cut every BLOCK_ROWS.
    def build_c
      writers = {rows: BlockWriter.new(file("c1.sqlite3"), :rows, side_table: true), cols: BlockWriter.new(file("c2.sqlite3"), :cols)}
      cpu = Hash.new(0.0)
      by_stream = nil
      step("C: build") do
        by_stream = streams
        by_stream.each do |stream, entries|
          entries.each_slice(BLOCK_ROWS) do |slice|
            t = LogsBlocksExperiment.now
            recs = @src.fetch_recs(slice.map(&:last))
            cpu["source read + JSON parse"] += LogsBlocksExperiment.now - t

            t = LogsBlocksExperiment.now
            tokens = Set.new
            recs.each do |r|
              fields = {service: stream[2], environment: stream[1], server_name: r.server_name, release: r.release}
              pairs = Tokens.attribute_pairs(r.payload) + Tokens.promoted_pairs(r.source, fields)
              bare, kv = Tokens.sets(r.body, pairs, {"trace_id" => r.trace_id, "log_id" => r.log_id})
              tokens.merge(bare).merge(kv)
            end
            cpu["tokenize"] += LogsBlocksExperiment.now - t

            t = LogsBlocksExperiment.now
            bloom = Bloom.build(tokens)
            cpu["bloom"] += LogsBlocksExperiment.now - t

            writers.each do |kind, w|
              t = LogsBlocksExperiment.now
              data = w.encode(recs)
              cpu["encode #{kind}"] += LogsBlocksExperiment.now - t
              t = LogsBlocksExperiment.now
              w.write(stream, recs, bloom, data)
              cpu["insert #{kind}"] += LogsBlocksExperiment.now - t
            end
          end
        end
        writers.each_value(&:close)
      end

      @results["c_cpu_us_per_log"] = cpu.transform_values { |s| (s * 1e6 / @src.rows).round(1) }
      @results["streams"] = by_stream.size
      {"C1" => writers[:rows], "C2" => writers[:cols]}.each do |arm, w|
        record_size(arm, w.path)
        @results["sizes"][arm].merge!("blocks" => w.blocks, "data_bytes" => w.data_bytes, "bloom_bytes" => w.bloom_bytes)
      end
      verify_round_trip
      bloom_false_positives
    end

    # Share of (block, absent token) checks the bloom lets through.
    def bloom_false_positives
      rng = Random.new(7)
      probes = Array.new(200) { Array.new(12) { ("a".."z").to_a.sample(random: rng) }.join }
      checks = 0
      passed = 0
      db = SQLite3::Database.new(file("c1.sqlite3"), readonly: true)
      db.execute("SELECT bloom FROM blocks") do |(bloom)|
        probes.each do |t|
          checks += 1
          passed += 1 if Bloom.include_all?(bloom, [t])
        end
      end
      db.close
      @results["bloom_false_positive_rate"] = (passed.to_f / [checks, 1].max).round(5)
    end

    # Spot-check that C1 and C2 hand back what went in, on 2,000 logs.
    def verify_round_trip
      sample = @src.db.execute("SELECT id FROM logs ORDER BY id LIMIT 2000").flatten
      expected = @src.fetch_recs(sample).to_h { |r| [r.log_id, r] }
      mismatches = {"C1" => 0, "C2" => 0}
      {"C1" => [:rows, "c1.sqlite3"], "C2" => [:cols, "c2.sqlite3"]}.each do |arm, (kind, name)|
        reader = BlockArm.new(file(name), kind)
        reader.open!
        db = SQLite3::Database.new(file(name), readonly: true)
        db.execute("SELECT id, min_ts FROM blocks") do |id, min_ts|
          blk = reader.block(id, min_ts)
          blk.size.times do |i|
            want = expected[blk.column(:log_id)[i]] or next
            same = blk.ts[i] == want.ts && blk.column(:body)[i] == want.body &&
              blk.column(:trace_id)[i] == want.trace_id && blk.column(:level)[i] == want.level &&
              blk.attr_pairs(i).sort_by { |k, _| k.to_s } == Tokens.attribute_pairs(want.payload).sort_by { |k, _| k.to_s }
            same &&= blk.payload(i) == BodyStrip.restore(want.payload, want.body) if kind == :rows
            mismatches[arm] += 1 unless same
          end
        end
        db.close
        reader.close!
      end
      @results["round_trip"] = {"checked" => expected.size, "mismatches" => mismatches}
    end

    # Before compaction: the flush job seals each stream's buffered logs every
    # FLUSH_SECONDS of ingest time. Size only, C1 encoding.
    def sealed_c
      step("C: sealed (pre-compaction) layout") do
        buckets = Hash.new { |h, k| h[k] = [] }
        @src.db.execute("SELECT id, project_id, environment, service, created_at FROM logs ORDER BY id") do |id, pid, env, svc, created|
          buckets[[pid, env, svc, LogsBlocksExperiment.ts_us(created) / (FLUSH_SECONDS * 1_000_000)]] << id
        end
        blocks = 0
        bytes = 0
        buckets.each do |key, ids|
          ids.each_slice(BLOCK_ROWS) do |slice|
            recs = @src.fetch_recs(slice)
            tokens = Set.new
            recs.each do |r|
              fields = {service: key[2], environment: key[1], server_name: r.server_name, release: r.release}
              pairs = Tokens.attribute_pairs(r.payload) + Tokens.promoted_pairs(r.source, fields)
              bare, kv = Tokens.sets(r.body, pairs, {"trace_id" => r.trace_id, "log_id" => r.log_id})
              tokens.merge(bare).merge(kv)
            end
            bytes += Bloom.build(tokens).bytesize + RowsBlock.encode(recs).bytesize
            blocks += 1
          end
        end
        @results["sizes"]["C1 sealed"] = {"blocks" => blocks, "payload_bytes" => bytes}
      end
    end

    def pick_params
      b = SQLite3::Database.new(file("b.sqlite3"))
      rng = Random.new(Integer(ENV.fetch("LOGS_SEED", "1")))
      total = b.get_first_value("SELECT COUNT(*) FROM logs")
      project = b.get_first_value("SELECT project_id FROM logs GROUP BY project_id ORDER BY COUNT(*) DESC LIMIT 1")
      b.execute("CREATE VIRTUAL TABLE temp.vocab USING fts5vocab(main, logs_fts, 'row')")
      in_project = ->(term) {
        b.get_first_value("SELECT COUNT(*) FROM logs WHERE project_id = ? AND id IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)",
          [project, Log.fts_query(term)]).to_i.positive?
      }
      pick_term = ->(where, binds = []) {
        terms = b.execute("SELECT term FROM temp.vocab WHERE #{where} LIMIT 20000", binds).flatten.shuffle(random: rng)
        terms.first(200).find { |t| in_project.call(t) }
      }

      params = {project: project, total: total}
      params[:rare_word] = pick_term.call("doc BETWEEN 3 AND 10 AND length(term) BETWEEN 6 AND 16 AND term NOT GLOB '*[0-9]*'")
      params[:rare_id] = pick_term.call("doc BETWEEN 2 AND 10 AND length(term) = 32 AND term NOT GLOB '*[^0-9a-f]*'")
      params[:common_word] = pick_term.call("doc BETWEEN ? AND ? AND length(term) >= 4 AND term NOT GLOB '*[0-9]*'", [total / 20, total / 5])
      params[:key_value] = pick_key_value(project, rng)
      params[:trace_id] = b.execute("SELECT trace_id FROM logs WHERE trace_id IS NOT NULL GROUP BY trace_id HAVING COUNT(*) BETWEEN 3 AND 100 LIMIT 1000")
        .flatten.sample(random: rng)
      lo, hi = b.execute("SELECT MIN(id), MAX(id) FROM logs").first
      params[:log_id] = b.get_first_value("SELECT log_id FROM logs WHERE id >= ? ORDER BY id LIMIT 1", [lo + rng.rand(hi - lo + 1)])
      slow_project, slow_n = b.execute("SELECT project_id, COUNT(*) FROM logs WHERE duration_ms IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 1").first
      if slow_project
        params[:slow_project] = slow_project
        params[:min_duration] = b.get_first_value("SELECT duration_ms FROM logs WHERE project_id = ? AND duration_ms IS NOT NULL ORDER BY duration_ms DESC LIMIT 1 OFFSET ?",
          [slow_project, slow_n / 1000])
      end
      b.close
      params
    end

    # A key:value present in 1-10% of a sample of the project's logs.
    def pick_key_value(project, rng)
      counts = Hash.new(0)
      sample = @src.db.execute("SELECT payload_blob, dict_id FROM logs WHERE project_id = ? LIMIT 5000", [project])
      sample.each do |blob, dict_id|
        Tokens.attribute_pairs(@src.payload(blob, dict_id)).each do |k, v|
          next unless v.is_a?(String) || v.is_a?(Integer)
          s = v.to_s
          next if s.empty? || s.length > 40 || s.match?(/\s/) || k.to_s.match?(/\s|:/)
          counts["#{k}:#{s}"] += 1
        end
      end
      lo = sample.size / 100
      hi = sample.size / 10
      counts.select { |_, n| n.between?(lo, hi) }.keys.sort.sample(random: rng)
    end

    def arms
      list = {}
      list["A"] = SqlArm.new(file("a.sqlite3"), :a, @src) if ARMS.include?("a")
      list["B"] = SqlArm.new(file("b.sqlite3"), :b, @src)
      if ARMS.include?("c")
        list["C1"] = BlockArm.new(file("c1.sqlite3"), :rows)
        list["C2"] = BlockArm.new(file("c2.sqlite3"), :cols)
      end
      list
    end

    def queries(p)
      q = {}
      q["newest 50"] = ->(a) { a.newest(p[:project]) }
      q["page 5 (offset 200)"] = ->(a) { a.newest(p[:project], offset: 200) }
      q["level:error newest 50"] = ->(a) { a.newest(p[:project], level: 4) }
      {rare_word: "rare word", rare_id: "rare id", common_word: "common word", key_value: "key:value"}.each do |key, label|
        q["#{label} #{p[key]}"] = ->(a) { a.newest(p[:project], text: p[key]) } if p[key]
      end
      q["absent word"] = ->(a) { a.newest(p[:project], text: ABSENT_TERM) }
      q["duration >= p99.9"] = ->(a) { a.newest(p[:slow_project], min_duration: p[:min_duration]) } if p[:min_duration]
      if p[:trace_id]
        q["trace, no time bound"] = ->(a) { a.trace(p[:trace_id]) }
        q["trace via side table"] = ->(a) { a.try(:side_table?) ? a.trace(p[:trace_id], via: :side) : :skip }
      end
      q["log_id lookup"] = ->(a) { a.by_log_id(p[:log_id]) }
      q["hourly timeline"] = ->(a) { a.timeline(p[:project]) }
      q["decode whole day"] = ->(a) { a.is_a?(BlockArm) ? a.full_scan : :skip }
      q
    end

    # Cold runs reopen the connection after dropping the file from the page
    # cache; warm runs follow one priming run.
    def measure(arm)
      cold = Array.new(COLD_RUNS) do
        arm.close!
        File.open(arm.path, "rb") { |f| f.advise(:dontneed, 0, 0) }
        arm.open!
        t0 = LogsBlocksExperiment.now
        yield
        (LogsBlocksExperiment.now - t0) * 1000
      end
      arm.close!
      arm.open!
      result = yield
      return nil if result == :skip
      warm = Array.new(WARM_RUNS) do
        t0 = LogsBlocksExperiment.now
        yield
        (LogsBlocksExperiment.now - t0) * 1000
      end
      {"warm_ms" => LogsBlocksExperiment.median(warm).round(1), "cold_ms" => LogsBlocksExperiment.median(cold)&.round(1)}
        .merge(result.transform_keys(&:to_s))
    end

    def run_queries
      params = step("Pick query parameters") { pick_params }
      @results["params"] = params
      puts "  #{params.inspect}"
      arm_list = arms
      queries(params).each do |name, query|
        print "Query: #{name} "
        row = {}
        arm_list.each do |arm_name, arm|
          stats = measure(arm) { query.call(arm) }
          arm.close!
          next unless stats
          row[arm_name] = stats
          print "."
        end
        baseline = row.dig("B", "ids")
        row.each_value do |stats|
          ids = stats.delete("ids")
          next unless ids
          stats["results"] = ids.size
          stats["same_as_B"] = baseline.nil? || ids == baseline
          stats["overlap_with_B"] = (ids & baseline).size if baseline && ids != baseline
        end
        @results["queries"][name] = row
        puts
      end
    end
  end

  class Report
    def initialize(results, rows)
      @r = results
      @rows = rows
    end

    def per_log(bytes) = bytes ? format("%.0f", bytes.to_f / @rows) : "—"

    def mb(bytes) = format("%.1f MB", bytes / 1024.0**2)

    def table(headers, rows)
      ([headers, headers.map { "---" }] + rows).map { |r| "| #{r.join(" | ")} |" }.join("\n")
    end

    def to_s
      s = @r["sizes"]
      out = []
      out << "# Logs storage experiment: #{@r.dig("export", "day")}, #{@rows} logs"
      out << "Settings: #{@r["settings"].to_json}"
      if (prod = ENV["LOGS_PROD_BYTES_PER_LOG"])
        out << "\nProduction's logs DB now: #{prod} bytes/log (LOGS_PROD_BYTES_PER_LOG)."
      end
      out << "\nRare, absent, trace and log_id queries that find fewer than 50 rows have to visit every day: " \
             "over 15 days of retention, about 15× the figures below."
      out << "\n## Bytes per log\n"
      size_rows = []
      %w[A B].each do |arm|
        next unless s[arm]
        bt = s[arm]["btrees"]
        size_rows << [arm, mb(s[arm]["bytes"]), per_log(s[arm]["bytes"]), per_log(bt["rows"]), per_log(bt["indexes"]), per_log(bt["fts"]), ""]
      end
      %w[C1 C2].each do |arm|
        next unless s[arm]
        bt = s[arm]["btrees"]
        side = bt["block_traces"].positive? ? "trace side table #{per_log(bt["block_traces"])} B/log (in total)" : ""
        size_rows << [arm, mb(s[arm]["bytes"]), per_log(s[arm]["bytes"]), "data #{per_log(s[arm]["data_bytes"])}", "", "bloom #{per_log(s[arm]["bloom_bytes"])}",
          "#{s[arm]["blocks"]} blocks, #{@rows / [s[arm]["blocks"], 1].max} logs/block. #{side}"]
      end
      out << table(["arm", "file", "bytes/log", "rows (or data)", "indexes", "FTS (or bloom)", "notes"], size_rows)
      if (fv = s["FTS variants"])
        out << "\nFTS alone, bytes/log: detail=full #{per_log(s.dig("B", "btrees", "fts"))}, " \
               "detail=column #{per_log(fv["btrees"]["fts_column"])}, detail=none #{per_log(fv["btrees"]["fts_none"])}"
      end
      if (sealed = s["C1 sealed"])
        out << "\nC1 before compaction (sealed every #{@r.dig("settings", "flush_seconds")}s of ingest): #{sealed["blocks"]} blocks, " \
               "#{@rows / [sealed["blocks"], 1].max} logs/block, #{per_log(sealed["payload_bytes"])} bytes/log of data + bloom " \
               "(compacted: #{per_log(s.dig("C1", "data_bytes").to_i + s.dig("C1", "bloom_bytes").to_i)})"
      end
      if s["B"] && (best = %w[C1 C2].filter_map { |a| s.dig(a, "bytes") }.min)
        out << format("\n**Best C against B: %.2f** (rule: ≤ 0.33 go, 0.33–0.5 judgement, > 0.5 ship B)", best.to_f / s["B"]["bytes"])
      end
      out << "\n## Queries (ms, median; warm / cold)\n"
      arms = @r["queries"].values.flat_map(&:keys).uniq
      q_rows = @r["queries"].map do |name, row|
        [name] + arms.map do |arm|
          st = row[arm] or next "—"
          extra = []
          extra << "#{st["results"]} rows" if st["results"]
          extra << "#{st["blocks_read"]} blocks read" if st["blocks_read"]
          extra << "differs from B (overlap #{st["overlap_with_B"]})" if st["same_as_B"] == false
          "#{st["warm_ms"]} / #{st["cold_ms"]}#{" (#{extra.join(", ")})" unless extra.empty?}"
        end
      end
      out << table(["query"] + arms, q_rows)
      out << "\nParams: #{@r["params"].to_json}"
      out << "\n## Block encode CPU, µs per log\n"
      out << (@r["c_cpu_us_per_log"] || {}).map { |k, v| "- #{k}: #{v}" }.join("\n")
      out << "\nBloom false-positive rate (absent tokens): #{@r["bloom_false_positive_rate"]}" if @r["bloom_false_positive_rate"]
      out << "\n## Round trip\n#{@r["round_trip"].to_json}" if @r["round_trip"]
      out << "\n## Lateness (created_at − timestamp)\n#{@r["lateness"].to_json}"
      out.join("\n")
    end
  end
end

abort "usage: bin/rails runner script/logs_blocks_experiment.rb <export.sqlite3>" unless ARGV[0] && File.exist?(ARGV[0])
LogsBlocksExperiment::Run.new(ARGV[0]).call

class StorageStats
  # Each entry is [label_for_ui, ActiveRecord base class]. The labels match
  # what the settings page renders as a section header.
  DBS = [
    ["Primary", "ApplicationRecord"],
    ["Issues + Events", "IssuesEventsRecord"],
    ["Transactions + Spans", "TransactionsSpansRecord"],
    ["Logs", "LogsRecord"]
  ].freeze

  # Where the precomputed snapshot lives. SolidCache is SQLite-backed and
  # survives restarts, so the snapshot is the refresher's responsibility, not
  # a TTL's — Maintenance::StorageStatsJob rewrites it on a schedule. Bump the
  # version suffix if the snapshot shape changes.
  CACHE_KEY = "storage_stats/snapshot/v3"

  # Compressed payload tables: [ui label, AR base class, codec db, table].
  # Defined on the class (not in `class << self`) so the settings view can
  # reference StorageStats::COMPRESSION_SAMPLE; internal singleton methods still
  # resolve the bare constants via lexical nesting.
  COMPRESSED = [
    ["Events", "IssuesEventsRecord", :issues_events, "events"],
    ["Logs", "LogsRecord", :logs, "logs"]
  ].freeze

  # Rows to decode per table to estimate the compression ratio. A few hundred
  # is plenty for a stable ratio and stays well under a second.
  COMPRESSION_SAMPLE = 500

  # Per-DB compression-dictionary state for the settings page:
  # [ui label, dict AR model, AR base class (for the runs table connection)].
  DICTIONARIES = [
    ["Events", "Compression::IssuesEventsDict", "IssuesEventsRecord"],
    ["Logs", "Compression::LogsDict", "LogsRecord"]
  ].freeze

  # How many recent training runs to keep per DB in the snapshot.
  RECENT_TRAINING_RUNS = 10

  class << self
    # The precomputed snapshot the settings page renders, or nil if one has
    # never been built (fresh deploy with a cold cache). Cheap — a single
    # cache read, no dbstat scan.
    def snapshot
      Rails.cache.read(CACHE_KEY)
    end

    # Run the heavy dbstat scan now and store the result. Called by
    # Maintenance::StorageStatsJob; never on the request path. Returns the
    # stored snapshot.
    def refresh!
      groups = sqlite_tables_grouped
      total = groups.sum { |g| g[:tables].sum { |t| t[:total_bytes] } }
      snap = {groups: groups, total: total, compression: compression_estimate,
              dictionaries: dictionary_status, collected_at: Time.current}
      Rails.cache.write(CACHE_KEY, snap)
      snap
    end

    # Estimate storage saved by zstd payload compression, per compressed table.
    # We don't store original sizes, so sample COMPRESSION_SAMPLE random blobs,
    # decode them, and compare decompressed vs stored bytes to get a ratio, then
    # scale by the table's blob row count. Heavy-ish (decodes a sample) — only
    # called from the 15-min StorageStatsJob, never on the request path.
    def compression_estimate
      COMPRESSED.filter_map do |label, base_name, db, table|
        conn = base_name.constantize.connection

        sample = conn.select_all(<<~SQL).to_a
          SELECT payload_blob AS blob, dict_id FROM #{table}
          WHERE payload_blob IS NOT NULL
          ORDER BY RANDOM() LIMIT #{COMPRESSION_SAMPLE}
        SQL
        next if sample.empty?

        compressed = 0
        original = 0
        counted = 0
        sample.each do |row|
          blob = row["blob"]
          next if blob.nil?
          decoded = Compression::Codec.decode(blob, db: db, dict_id: row["dict_id"])
          compressed += blob.bytesize
          original += decoded.to_s.bytesize
          counted += 1
        rescue => e
          Rails.logger.warn("StorageStats: skipped a #{table} blob: #{e.class}: #{e.message}")
        end
        next if counted.zero? || compressed.zero?

        blob_rows = conn.select_value("SELECT COUNT(*) FROM #{table} WHERE payload_blob IS NOT NULL").to_i
        ratio = original.to_f / compressed
        est_stored = (compressed.to_f / counted * blob_rows).round
        est_original = (est_stored * ratio).round

        {
          name: label,
          rows: blob_rows,
          sample: counted,
          ratio: ratio,
          stored_bytes: est_stored,
          original_bytes: est_original,
          saved_bytes: est_original - est_stored
        }
      end
    rescue => e
      Rails.logger.warn("StorageStats.compression_estimate failed: #{e.class}: #{e.message}")
      []
    end

    # Per-DB compression-dictionary state: the trained zstd dictionaries (one
    # active per segment) plus the most recent training-run log entries. Cheap
    # — both tables are tiny — but only called from the StorageStatsJob so the
    # request path stays a single cache read. A nil trained_at / empty runs is
    # meaningful (e.g. a seeded dict the daily drift job has never revisited),
    # so the view renders those states rather than hiding them.
    def dictionary_status
      DICTIONARIES.filter_map do |label, model_name, base_name|
        model = model_name.constantize
        conn = base_name.constantize.connection

        dicts = model.order(:segment, version: :desc).map do |d|
          {segment: d.segment, version: d.version, active: d.active,
           trained_at: d.trained_at, baseline_ratio: d.baseline_ratio,
           sample_count: d.sample_count}
        end

        runs = conn.select_all(<<~SQL).to_a.map do |r|
          SELECT segment, ran_at, samples, current_ratio, candidate_ratio,
                 gain, promoted, promoted_to_version, notes
          FROM dictionary_training_runs ORDER BY ran_at DESC LIMIT #{RECENT_TRAINING_RUNS}
        SQL
          {segment: r["segment"], ran_at: parse_time(r["ran_at"]), samples: r["samples"],
           current_ratio: r["current_ratio"], candidate_ratio: r["candidate_ratio"],
           gain: r["gain"], promoted: r["promoted"].to_i == 1,
           promoted_to_version: r["promoted_to_version"], notes: r["notes"]}
        end

        {name: label, dicts: dicts, runs: runs}
      rescue => e
        Rails.logger.warn("StorageStats.dictionary_status(#{label}) failed: #{e.class}: #{e.message}")
        nil
      end
    end

    # Ask the maintenance pool to (re)build the snapshot. Idempotent via the
    # tuber idp key, so a burst of cache-miss requests on a cold cache enqueues
    # at most one scan. Safe to call from a web request — it only puts a job.
    def enqueue_refresh
      Ingest::Tuber.put(
        Ingest::Tuber::MAINTENANCE_TUBE,
        {class: "Maintenance::StorageStatsJob", args: []},
        con: 1, idp: "storage_stats"
      )
    rescue => e
      Rails.logger.warn("StorageStats.enqueue_refresh failed: #{e.class}: #{e.message}")
    end

    # Tables across all three SQLite files, grouped by source DB so the
    # settings page can show them per-cluster. Each table row gives the row
    # count, table bytes, index bytes, and total bytes.
    def sqlite_tables_grouped
      DBS.map do |label, base_name|
        base = base_name.constantize
        {name: label, base: base_name, tables: sqlite_tables_for(base)}
      end
    end

    # Back-compat single-list view (primary only) — kept for any caller
    # not yet updated to the grouped form.
    def sqlite_tables
      sqlite_tables_for(ApplicationRecord)
    end

    private

    def sqlite_tables_for(base)
      conn = base.connection
      byte_map = page_bytes_by_object(conn)

      indexes_by_table = Hash.new { |h, k| h[k] = [] }
      conn.select_all("SELECT name, tbl_name FROM sqlite_master WHERE type = 'index'").each do |row|
        indexes_by_table[row["tbl_name"]] << row["name"]
      end

      tables = conn.select_all(<<~SQL).to_a
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name
      SQL

      tables.map { |row|
        name = row["name"]
        row_count = conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(name)}").to_i
        table_bytes = byte_map[name].to_i
        index_bytes = indexes_by_table[name].sum { |idx| byte_map[idx].to_i }
        {
          name: name,
          row_estimate: row_count,
          table_bytes: table_bytes,
          index_bytes: index_bytes,
          total_bytes: table_bytes + index_bytes
        }
      }.sort_by { |t| -t[:total_bytes] }
    end

    # SQLite returns datetimes as strings over a raw connection. Coerce to Time
    # for consistent formatting in the view; tolerate nil/garbage.
    def parse_time(value)
      return value if value.nil? || value.is_a?(Time)
      Time.zone ? Time.zone.parse(value.to_s) : Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def page_bytes_by_object(conn)
      conn.select_all("SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name").each_with_object({}) do |row, h|
        h[row["name"]] = row["bytes"].to_i
      end
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("StorageStats: dbstat unavailable (#{e.class}: #{e.message}); per-table byte sizes will be 0")
      {}
    end
  end
end

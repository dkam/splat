class StorageStats
  # Each entry is [label_for_ui, ActiveRecord base class]. The labels match
  # what the settings page renders as a section header.
  DBS = [
    ["Primary", "ApplicationRecord"],
    ["Issues + Events", "IssuesEventsRecord"],
    ["Transactions + Spans", "TransactionsSpansRecord"],
    ["Logs", "LogsRecord"]
  ].freeze

  # Bump ONLY when the snapshot Hash *shape* changes — a new key, a new table
  # group, a renamed field. Not on every release. See CACHE_KEY.
  SNAPSHOT_SCHEMA = 1

  # Where the precomputed snapshot lives. SolidCache is SQLite-backed and
  # survives restarts, so the snapshot is the refresher's responsibility, not
  # a TTL's — Maintenance::StorageStatsJob rewrites it on a schedule.
  #
  # Keyed on SNAPSHOT_SCHEMA, deliberately NOT Splat::VERSION. Versioning on the
  # app version invalidated this on every deploy, and the deep pass that rebuilds
  # it takes ~40 min on a 100GB+ instance — so each release showed the settings
  # page's "Calculating…" state until an uninterrupted pass finished, and a
  # deploy landing mid-pass reset it to cold again. The only reason to invalidate
  # is a change to the snapshot's shape, which is manual and rare; across an
  # ordinary deploy a stale-but-present snapshot degrades to the honest
  # "collected N ago" data the view already renders, never a crash.
  CACHE_KEY = "storage_stats/snapshot/v#{SNAPSHOT_SCHEMA}"

  # Compressed payload tables: [ui label, AR base class, codec db, table].
  # Defined on the class (not in `class << self`) so the settings view can
  # reference StorageStats::COMPRESSION_SAMPLE; internal singleton methods still
  # resolve the bare constants via lexical nesting.
  COMPRESSED = [
    ["Events", "IssuesEventsRecord", :issues_events, "events"],
    ["Logs", "LogsRecord", :logs, "logs"],
    # Spans: one plain-zstd blob per transaction (span_trees). dict_id is nil
    # (no trained dict yet), so Compression::Codec falls back to plain zstd —
    # same code path, no DictStore needed for this DB.
    ["Spans", "TransactionsSpansRecord", :transactions_spans, "span_trees"]
  ].freeze

  # Rows to decode per table to estimate the compression ratio. A few hundred
  # is plenty for a stable ratio and stays well under a second.
  COMPRESSION_SAMPLE = 500

  # The sample is gathered as COMPRESSION_ANCHORS short runs of consecutive
  # rows, each starting at a random rowid, rather than `ORDER BY RANDOM() LIMIT
  # n` — SQLite can't push a limit into a random sort, so that form materialises
  # and sorts the whole table (a full scan plus a spill-to-disk sort of a 90GB
  # file, every run). Anchored runs are index seeks into the rowid b-tree.
  # Spreading over many anchors keeps the sample representative: payloads
  # correlate with time, and rowid order is insertion order, so a single run of
  # 500 would only measure one moment's traffic.
  COMPRESSION_ANCHORS = 25

  # Per-DB compression-dictionary state for the settings page:
  # [ui label, dict AR model, AR base class (for the runs table connection)].
  DICTIONARIES = [
    ["Events", "Compression::IssuesEventsDict", "IssuesEventsRecord"],
    ["Logs", "Compression::LogsDict", "LogsRecord"]
  ].freeze

  # How many recent training runs to keep per DB in the snapshot.
  RECENT_TRAINING_RUNS = 10

  # Data tables whose time span answers "how far back do we actually keep X?".
  # [ui label, AR base class, table, time column]. Every column here is indexed,
  # but that alone doesn't make the bounds cheap — see #data_span for why MIN and
  # MAX have to be queried separately. The histogram/hourly_stats rows are what
  # the performance sparklines read, so their span is the real "days of spark
  # data" answer — distinct from raw transaction retention.
  DATA_SPAN = [
    ["Events", "IssuesEventsRecord", "events", "timestamp"],
    ["Transactions", "TransactionsSpansRecord", "transactions", "timestamp"],
    ["Span trees", "TransactionsSpansRecord", "span_trees", "timestamp"],
    ["Transaction histograms (spark)", "TransactionsSpansRecord", "transaction_histograms", "hour_bucket"],
    ["Transaction hourly stats", "TransactionsSpansRecord", "transaction_hourly_stats", "hour_bucket"],
    ["Logs", "LogsRecord", "logs", "timestamp"]
  ].freeze

  class << self
    # The precomputed snapshot the settings page renders, or nil if one has
    # never been built (fresh deploy with a cold cache). Cheap — a single
    # cache read, no dbstat scan.
    def snapshot
      Rails.cache.read(CACHE_KEY)
    end

    # The cheap pass: everything that costs index seeks rather than full scans.
    # Called hourly by Maintenance::StorageStatsJob; never on the request path.
    #
    # The per-table `groups` breakdown and the row `counts` derived from it are
    # NOT recomputed here — both need dbstat and COUNT(*), which read every page
    # of every DB. Those come from the last refresh_deep! and are carried
    # forward; `deep_collected_at` tells the view how stale they are. The
    # headline total is still live, from PRAGMA page_count.
    def refresh!
      prior = snapshot

      # A cold cache has no deep pass to carry forward, and CACHE_KEY is
      # versioned on Splat::VERSION so every deploy starts cold. Writing a
      # snapshot with empty groups here would be doubly wrong: the settings page
      # would show no per-table breakdown and no counts, and the controller's
      # cold-cache deep enqueue would never fire again — it only triggers when
      # the snapshot is nil, and we'd just made it non-nil. Build the real thing
      # once instead. Self-healing, and it doesn't depend on anyone loading the
      # settings page to kick off the first deep pass.
      return refresh_deep! if prior.nil? || prior[:deep_collected_at].nil?

      groups = prior[:groups] || []
      snap = {groups: groups,
              total: file_bytes_total,
              counts: prior[:counts] || {},
              compression: compression_estimate(row_counts(groups)),
              dictionaries: dictionary_status,
              data_span: data_span,
              collected_at: Time.current,
              deep_collected_at: prior[:deep_collected_at]}
      Rails.cache.write(CACHE_KEY, snap)
      snap
    end

    # The full pass, including the dbstat page walk and a COUNT(*) per table.
    # O(total file size) — ~two full reads of every DB — so this runs daily,
    # not hourly. Also the cold-cache path: refresh! carries `groups` forward
    # rather than building them, so a snapshot has to start life here.
    def refresh_deep!
      groups = sqlite_tables_grouped
      now = Time.current
      snap = {groups: groups,
              total: file_bytes_total,
              counts: counts(groups),
              compression: compression_estimate(row_counts(groups)),
              dictionaries: dictionary_status,
              data_span: data_span,
              collected_at: now,
              deep_collected_at: now}
      Rails.cache.write(CACHE_KEY, snap)
      snap
    end

    # Total on-disk bytes across every DB, via PRAGMA page_count — two integer
    # reads from each file's header, no page walk. Slightly larger than summing
    # dbstat table bytes, because it counts free pages the file still occupies:
    # that's the honest "how big is this on disk" number the headline wants.
    def file_bytes_total
      DBS.sum do |_label, base_name|
        conn = base_name.constantize.connection
        conn.select_value("PRAGMA page_count").to_i * conn.select_value("PRAGMA page_size").to_i
      rescue => e
        Rails.logger.warn("StorageStats.file_bytes_total(#{base_name}) failed: #{e.class}: #{e.message}")
        0
      end
    end

    # Headline row counts for the settings "Counts" block — read off the
    # snapshot so the request path never scans these tables. Derived from the
    # row_estimates already gathered for `groups` (no re-count), except spans:
    # new spans live *inside* span_trees blobs (one row per transaction, each
    # carrying a span_count), not as `spans` rows, so the true span total is the
    # legacy spans rows plus the sum of span_count across span_trees. As the
    # legacy rows age out of retention this trends to "all from span_trees"
    # rather than counting down to zero.
    def counts(groups)
      rows = {}
      groups.each { |g| g[:tables].each { |t| rows[t[:name]] = t[:row_estimate] } }
      {
        issues: rows["issues"].to_i,
        events: rows["events"].to_i,
        transactions: rows["transactions"].to_i,
        spans: rows["spans"].to_i + SpanTree.sum(:span_count).to_i,
        logs: rows["logs"].to_i,
        # The spark data behind the performance charts. Already scanned as part
        # of the deep pass's per-table walk, so read it off `groups` rather than
        # a live COUNT(*) on the request path (it's a 90GB DB).
        histogram_rows: rows["transaction_histograms"].to_i
      }
    rescue => e
      Rails.logger.warn("StorageStats.counts failed: #{e.class}: #{e.message}")
      {}
    end

    # Oldest/newest row per data table → the real retention window. Runs on the
    # hourly pass, never on the request path. Empty tables yield nil bounds
    # (rendered as "—"); a missing table is skipped, not fatal.
    #
    # MIN and MAX are queried separately on purpose. SQLite only rewrites an
    # aggregate into an index seek when it's the lone aggregate in the query:
    # `SELECT MIN(x), MAX(x)` falls back to a full scan of the index, while two
    # `SELECT MIN(x)` / `SELECT MAX(x)` statements are two O(log n) seeks.
    # Confirm with EXPLAIN QUERY PLAN before merging these back together —
    # SEARCH is the seek, SCAN is not.
    def data_span
      DATA_SPAN.filter_map do |label, base_name, table, column|
        conn = base_name.constantize.connection
        oldest = parse_time(conn.select_value("SELECT MIN(#{column}) FROM #{table}"))
        newest = parse_time(conn.select_value("SELECT MAX(#{column}) FROM #{table}"))
        days = (oldest && newest) ? ((newest - oldest) / 1.day.to_f).round(1) : nil
        {name: label, table: table, oldest: oldest, newest: newest, days: days}
      rescue => e
        Rails.logger.warn("StorageStats.data_span(#{table}) failed: #{e.class}: #{e.message}")
        nil
      end
    end

    # Estimate storage saved by zstd payload compression, per compressed table.
    # We don't store original sizes, so sample blobs, decode them, and compare
    # decompressed vs stored bytes to get a ratio, then scale by the table's
    # blob row count. `table_rows` maps table name => row count from the last
    # deep pass; a table missing from it is skipped rather than counted inline,
    # since COUNT(*) here would undo the point of the cheap sampling.
    def compression_estimate(table_rows = {})
      COMPRESSED.filter_map do |label, base_name, db, table|
        conn = base_name.constantize.connection
        total_rows = table_rows[table]
        next if total_rows.nil? || total_rows.zero?

        sample = sample_rows(conn, table)
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

        # The sample is taken without filtering on payload_blob, so the share of
        # sampled rows that carried one scales the row count into a blob count —
        # what COUNT(*) WHERE payload_blob IS NOT NULL used to answer exactly.
        with_blob = sample.count { |r| r["blob"] }
        blob_rows = (total_rows * (with_blob.to_f / sample.size)).round
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

    # Ask the maintenance pool to build the snapshot from scratch. Called on a
    # cold cache, so it has to be the deep job: refresh! carries `groups`
    # forward from a previous deep pass and would produce a snapshot with no
    # per-table breakdown at all. Idempotent via the tuber idp key, so a burst
    # of cache-miss requests enqueues at most one scan. Safe to call from a web
    # request — it only puts a job.
    def enqueue_refresh
      Ingest::Tuber.put(
        Ingest::Tuber::MAINTENANCE_TUBE,
        {class: "Maintenance::StorageStatsJob", args: ["deep"]},
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

    # table name => row count, from a `groups` breakdown built by a deep pass.
    def row_counts(groups)
      groups.each_with_object({}) do |g, h|
        g[:tables].each { |t| h[t[:name]] = t[:row_estimate].to_i }
      end
    end

    # Up to COMPRESSION_SAMPLE rows, gathered as COMPRESSION_ANCHORS short runs
    # starting at random rowids (see COMPRESSION_ANCHORS for why not
    # ORDER BY RANDOM()). Rows are returned unfiltered — callers need the share
    # carrying a payload_blob, not just the blobs themselves.
    #
    # Retention deletes leave holes in the rowid space, so an anchor can land in
    # a gap; `id >= anchor` walks forward to the next live row, which is why
    # this samples rows rather than ids. Anchors near the top of the range
    # return short runs; that costs a few samples, not representativeness.
    def sample_rows(conn, table)
      lo = conn.select_value("SELECT MIN(id) FROM #{table}")
      hi = conn.select_value("SELECT MAX(id) FROM #{table}")
      return [] if lo.nil? || hi.nil?

      span = hi.to_i - lo.to_i + 1
      per_anchor = [COMPRESSION_SAMPLE / COMPRESSION_ANCHORS, 1].max

      COMPRESSION_ANCHORS.times.flat_map do
        anchor = lo.to_i + Random.rand(span)
        conn.select_all(<<~SQL).to_a
          SELECT payload_blob AS blob, dict_id FROM #{table}
          WHERE id >= #{anchor}
          ORDER BY id LIMIT #{per_anchor}
        SQL
      end
    end

    def sqlite_tables_for(base)
      conn = base.connection
      byte_map, cell_map = dbstat_by_object(conn)

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
        # Row count comes from the same dbstat walk as the byte sizes: leaf-page
        # cells in a table's btree are exactly its rows (see dbstat_by_object).
        # Exact and free — no separate COUNT(*) per table (which was a second
        # full read of the whole dataset), and no ANALYZE estimate (unusable: a
        # bounded analysis_limit read `transactions` as ~100M rows against 5.7M
        # actual). Falls back to COUNT(*) only if dbstat is unavailable, so the
        # sizes and the counts degrade together rather than half the row lying.
        row_count = cell_map[name] ||
          conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(name)}").to_i
        table_bytes = byte_map[name].to_i
        # Keep each index's own size, not just the per-table sum: "which of
        # these seven indexes is worth dropping?" is only answerable from the
        # breakdown, and dbstat has already been walked to get here.
        indexes = indexes_by_table[name].map { |idx|
          {name: idx, bytes: byte_map[idx].to_i}
        }.sort_by { |i| -i[:bytes] }
        {
          name: name,
          row_estimate: row_count,
          table_bytes: table_bytes,
          index_bytes: indexes.sum { |i| i[:bytes] },
          indexes: indexes,
          total_bytes: table_bytes + indexes.sum { |i| i[:bytes] }
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

    # Bytes and row counts for every table/index in one dbstat pass. The walk we
    # already pay for to size each object also yields its row count, so there's
    # no separate COUNT(*) per table — that was a second full read of the whole
    # dataset, roughly half the deep pass's runtime on a 100GB+ instance.
    #
    #   SUM(pgsize)                          → the object's on-disk bytes.
    #   SUM(ncell) over *leaf* pages of a    → its row count. A table btree stores
    #   table's btree                          one cell per row in its leaf pages;
    #                                          interior pages carry pointer cells
    #                                          (excluded) and overflow pages carry
    #                                          none, so leaf cells == rows exactly.
    #
    # Index objects also get a leaf-cell count, but the caller only ever looks up
    # table names. Returns [bytes_by_name, rows_by_name]; on dbstat failure both
    # are empty and the caller falls back to COUNT(*) so sizes and counts stay
    # consistent (either both real or both from the fallback).
    def dbstat_by_object(conn)
      bytes = {}
      rows = {}
      conn.select_all(<<~SQL).each do |row|
        SELECT name,
               SUM(pgsize) AS bytes,
               SUM(CASE WHEN pagetype = 'leaf' THEN ncell ELSE 0 END) AS leaf_cells
        FROM dbstat GROUP BY name
      SQL
        bytes[row["name"]] = row["bytes"].to_i
        rows[row["name"]] = row["leaf_cells"].to_i
      end
      [bytes, rows]
    rescue ActiveRecord::StatementInvalid => e
      Rails.logger.warn("StorageStats: dbstat unavailable (#{e.class}: #{e.message}); per-table byte sizes and counts will fall back")
      [{}, {}]
    end
  end
end

require "fileutils"
require "open3"
require "tmpdir"

module Compression
  # Trains a candidate zstd dictionary for one segment and promotes it if it
  # beats the current active dict by more than GAIN_THRESHOLD.
  #
  # A segment's first component names the compressed table; the qualifier picks
  # the specialisation:
  #   "events"                    → events                (table-wide)
  #   "events:platform:python"    → events WHERE platform=python
  #   "events:project:42"         → events WHERE project_id=42
  #   "logs:platform:sentry"      → logs   WHERE source=sentry
  # REGISTRY maps the table to the DB it lives on plus the dict model scoped to
  # that DB — dict bytes and dict_id stay in the same file as the data.
  #
  # Promotion threshold is intentionally conservative — we want fewer,
  # better versions, not version churn.
  #
  # Memory: samples are decoded one row at a time and streamed straight to the
  # tmpdir — never the whole set in RAM. Decoded payloads are far larger than
  # their stored blobs (a production event is ~3.5 KB stored, ~80 KB decoded,
  # ~23× — full Sentry payloads with stack traces and breadcrumbs), so holding
  # 10k of them at once was ~750 MB and OOM-killed the 512 MB ingest worker.
  # We cap the training corpus by *bytes* (TRAIN_MAX_BYTES), which both bounds
  # the worker and `zstd --train`'s own footprint, and auto-tunes across
  # segments (a few fat events, or many small logs — same ceiling). A 112 KB
  # dict needs only ~20 MB of training data; more adds little, especially on
  # large payloads where zstd's own window already captures the redundancy.
  class DictTrainingJob
    SAMPLES = 10_000               # max rows to pull into the random pool
    TRAIN_MAX_BYTES = 24 * 1024 * 1024  # decoded-byte budget for the training set
    EVAL_RATIO = 5                 # every Nth sample goes to eval (≈20%)
    # `zstd --train` reads only the first 128 KB of each sample (ZDICT's
    # per-sample window — facebook/zstd#3111) and warns on "very large"
    # samples. Truncating training samples to that window is therefore free —
    # identical training input — and stops a fat payload's unread tail from
    # eating the TRAIN_MAX_BYTES budget, so it buys more *distinct* samples.
    # Eval samples are left whole: they measure real end-to-end compression.
    ZSTD_SAMPLE_WINDOW = 131_072
    LOOKBACK_DAYS = 7
    DICT_MAX_BYTES = 112_640      # zstd default
    GAIN_THRESHOLD = 0.10          # 10% — bottom of the user-stated range

    # table => { db:, record:, dict:, platform_column: }. platform_column is the
    # SQL column a "table:platform:X" qualifier filters on (events segment by
    # SDK platform; logs segment by source).
    REGISTRY = {
      "events" => {db: :issues_events, record: "IssuesEventsRecord", dict: "Compression::IssuesEventsDict", platform_column: "platform"},
      "logs" => {db: :logs, record: "LogsRecord", dict: "Compression::LogsDict", platform_column: "source"}
    }.freeze

    def perform(segment)
      table = segment.to_s.split(":").first
      entry = REGISTRY[table] or
        raise ArgumentError, "DictTrainingJob: no registry entry for segment #{segment.inspect}"
      db = entry[:db]
      Rails.logger.info "[DictTrainingJob] training #{segment}"

      Dir.mktmpdir("zstd-train-") do |dir|
        train_dir = File.join(dir, "train")
        eval_dir = File.join(dir, "eval")
        Dir.mkdir(train_dir)
        Dir.mkdir(eval_dir)

        total = stream_samples(db: db, table: table, segment: segment,
          train_dir: train_dir, eval_dir: eval_dir)
        if total < 100
          log_run(db: db, segment: segment, samples: total, notes: "skipped: too few samples")
          next
        end

        candidate_bytes = train_candidate(train_dir)

        eval_files = Dir[File.join(eval_dir, "*")]
        eval_total = eval_files.sum { |f| File.size(f) }
        current = active_dict_bytes(db, segment)
        current_size = current ? compressed_size(eval_files, current) : nil
        candidate_size = compressed_size(eval_files, candidate_bytes)
        gain = current.nil? ? 1.0 : (current_size - candidate_size).to_f / current_size

        promoted_version = nil
        if gain > GAIN_THRESHOLD
          promoted_version = promote!(db: db, segment: segment, bytes: candidate_bytes,
            baseline_ratio: candidate_size.to_f / eval_total,
            sample_count: total)
        end

        log_run(
          db: db, segment: segment,
          samples: total,
          current_ratio: current ? current_size.to_f / eval_total : nil,
          candidate_ratio: candidate_size.to_f / eval_total,
          gain: gain,
          promoted: !promoted_version.nil?,
          promoted_to_version: promoted_version
        )
      end
    end

    private

    # Pull a random pool of rows, decode each one at a time, and write it
    # straight to the train or eval dir — peak memory is one decoded payload
    # plus the (compressed) result set, never the whole decoded corpus. Stops
    # once the training set reaches TRAIN_MAX_BYTES of decoded data. Returns the
    # number of samples written (train + eval).
    def stream_samples(db:, table:, segment:, train_dir:, eval_dir:)
      conn = REGISTRY.fetch(table)[:record].constantize.connection
      since = LOOKBACK_DAYS.days.ago

      qualifier_sql, qualifier_bind = segment_qualifier(table, segment)
      binds = [since]
      binds << qualifier_bind if qualifier_bind

      rows = conn.exec_query(<<~SQL.squish, "DictTrainingJob sample", binds)
        SELECT payload_blob, dict_id
          FROM #{table}
         WHERE timestamp >= ?
           AND payload_blob IS NOT NULL
           #{qualifier_sql}
         ORDER BY RANDOM()
         LIMIT #{SAMPLES.to_i}
      SQL

      train_n = 0
      eval_n = 0
      train_bytes = 0
      rows.rows.each do |(blob, dict_id)|
        payload = Compression::Codec.decode(blob, db: db, dict_id: dict_id)
        next if payload.nil?

        written = train_n + eval_n
        if (written % EVAL_RATIO).zero?
          File.binwrite(File.join(eval_dir, "s-#{eval_n}.json"), payload)
          eval_n += 1
        else
          sample = payload.byteslice(0, ZSTD_SAMPLE_WINDOW)
          File.binwrite(File.join(train_dir, "s-#{train_n}.json"), sample)
          train_n += 1
          train_bytes += sample.bytesize
        end
        break if train_bytes >= TRAIN_MAX_BYTES
      end
      train_n + eval_n
    end

    # Translate a segment qualifier into a SQL fragment + bind. The "platform"
    # kind filters on the table's segmentation column (events → platform,
    # logs → source); the column name comes from REGISTRY, not user input.
    #   "events"                  → ["", nil]
    #   "events:platform:python"  → ["AND platform = ?", "python"]
    #   "events:project:42"       → ["AND project_id = ?", 42]
    #   "logs:platform:sentry"    → ["AND source = ?", "sentry"]
    def segment_qualifier(table, segment)
      return ["", nil] if segment.to_s == table
      _, kind, *value_parts = segment.to_s.split(":")
      value = value_parts.join(":")
      case kind
      when "platform" then ["AND #{REGISTRY.fetch(table)[:platform_column]} = ?", value]
      when "project" then ["AND project_id = ?", Integer(value)]
      else
        raise ArgumentError, "DictTrainingJob: unknown segment qualifier #{kind.inspect} in #{segment.inspect}"
      end
    end

    def train_candidate(train_dir)
      out_path = File.join(train_dir, "candidate.dict")
      files = Dir[File.join(train_dir, "s-*.json")]
      cmd = ["zstd", "--train", "--maxdict=#{DICT_MAX_BYTES}", "-o", out_path, *files]
      out, status = Open3.capture2e(*cmd)
      raise "zstd --train failed: #{out}" unless status.success?
      File.binread(out_path)
    end

    def active_dict_bytes(db, segment)
      id = Compression::DictStore.active_id(db, segment)
      return nil unless id
      Compression::DictStore.fetch(db, id).bytes
    end

    # Compress each eval sample on its own, reading from disk one at a time so
    # the eval corpus never sits in memory all at once.
    def compressed_size(eval_files, dict_bytes)
      eval_files.sum { |f| Zstd.compress(File.binread(f), level: Compression::Codec::LEVEL, dict: dict_bytes).bytesize }
    rescue ArgumentError
      # nil dict_bytes — fall back to plain zstd.
      eval_files.sum { |f| Zstd.compress(File.binread(f), level: Compression::Codec::LEVEL).bytesize }
    end

    def promote!(db:, segment:, bytes:, baseline_ratio:, sample_count:)
      klass = dict_model_for(segment)
      klass.transaction do
        klass.where(segment: segment, active: true).update_all(active: false)
        next_version = (klass.where(segment: segment).maximum(:version) || 0) + 1
        klass.create!(
          segment: segment,
          version: next_version,
          dict: bytes,
          trained_at: Time.current,
          sample_count: sample_count,
          baseline_ratio: baseline_ratio,
          active: true
        )
        Compression::DictStore.invalidate_active(db, segment)
        next_version
      end
    end

    def dict_model_for(segment)
      table = segment.to_s.split(":").first
      REGISTRY.fetch(table)[:dict].constantize
    end

    def log_run(db:, segment:, samples:, current_ratio: nil, candidate_ratio: nil, gain: nil,
      promoted: false, promoted_to_version: nil, notes: nil)
      dict_model_for(segment).connection.exec_insert(
        <<~SQL,
          INSERT INTO dictionary_training_runs
            (segment, ran_at, samples, current_ratio, candidate_ratio, gain, promoted, promoted_to_version, notes)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        "DictTrainingJob log",
        [segment, Time.current, samples, current_ratio, candidate_ratio, gain,
          promoted ? 1 : 0, promoted_to_version, notes]
      )
    end
  end
end

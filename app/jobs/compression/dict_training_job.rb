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
  class DictTrainingJob
    SAMPLES = 10_000
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

      samples = sample_payloads(db: db, table: table, segment: segment, n: SAMPLES)
      if samples.size < 100
        log_run(db: db, segment: segment, samples: samples.size, notes: "skipped: too few samples")
        return
      end

      train_set, eval_set = split(samples)
      candidate_bytes = train_candidate(train_set)

      current = active_dict_bytes(db, segment)
      current_size = compressed_size(eval_set, current)
      candidate_size = compressed_size(eval_set, candidate_bytes)
      gain = current.nil? ? 1.0 : (current_size - candidate_size).to_f / current_size

      promoted_version = nil
      if gain > GAIN_THRESHOLD
        promoted_version = promote!(db: db, segment: segment, bytes: candidate_bytes,
          baseline_ratio: candidate_size.to_f / eval_set.sum(&:bytesize),
          sample_count: samples.size)
      end

      log_run(
        db: db, segment: segment,
        samples: samples.size,
        current_ratio: current ? current_size.to_f / eval_set.sum(&:bytesize) : nil,
        candidate_ratio: candidate_size.to_f / eval_set.sum(&:bytesize),
        gain: gain,
        promoted: !promoted_version.nil?,
        promoted_to_version: promoted_version
      )
    end

    private

    def sample_payloads(db:, table:, segment:, n:)
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
         LIMIT #{n.to_i}
      SQL
      rows.rows.map do |(blob, dict_id)|
        Compression::Codec.decode(blob, db: db, dict_id: dict_id)
      end.compact
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

    # Disjoint 80/20 train/eval split, randomised.
    def split(samples, train_ratio: 0.8)
      shuffled = samples.shuffle
      cut = (shuffled.size * train_ratio).floor
      [shuffled[0...cut], shuffled[cut..]]
    end

    def train_candidate(samples)
      Dir.mktmpdir("zstd-train-") do |dir|
        samples.each_with_index { |bytes, i| File.binwrite(File.join(dir, "sample-#{i}.json"), bytes) }
        out_path = File.join(dir, "candidate.dict")
        cmd = ["zstd", "--train", "--maxdict=#{DICT_MAX_BYTES}",
          "-o", out_path, *Dir[File.join(dir, "sample-*.json")]]
        out, status = Open3.capture2e(*cmd)
        raise "zstd --train failed: #{out}" unless status.success?
        File.binread(out_path)
      end
    end

    def active_dict_bytes(db, segment)
      id = Compression::DictStore.active_id(db, segment)
      return nil unless id
      Compression::DictStore.fetch(db, id).bytes
    end

    def compressed_size(samples, dict_bytes)
      samples.sum { |s| Zstd.compress(s, level: Compression::Codec::LEVEL, dict: dict_bytes).bytesize }
    rescue ArgumentError
      # nil dict_bytes — fall back to plain zstd.
      samples.sum { |s| Zstd.compress(s, level: Compression::Codec::LEVEL).bytesize }
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

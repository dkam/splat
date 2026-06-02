# frozen_string_literal: true

# Train per-table zstd dictionaries from production-shaped data.
#
# Usage:
#   bin/rails zstd:train                       # all three, default 10_000 samples each
#   bin/rails zstd:train SAMPLES=20000
#   bin/rails zstd:train ONLY=events
#   bin/rails zstd:train DAYS=14 DICT_SIZE=131072
#
# Output: db/zstd_dicts/<table>.dict
# Requires the `zstd` CLI on PATH.
namespace :zstd do
  desc "Train zstd dictionaries for events/transactions/spans payloads"
  task train: :environment do
    require "fileutils"
    require "tmpdir"
    require "json"

    samples   = Integer(ENV.fetch("SAMPLES", 10_000))
    days      = Integer(ENV.fetch("DAYS", 7))
    dict_size = Integer(ENV.fetch("DICT_SIZE", 112_640)) # zstd default
    only      = ENV["ONLY"]&.split(",")&.map(&:strip)
    out_dir   = Rails.root.join("db", "zstd_dicts")
    FileUtils.mkdir_p(out_dir)

    since = days.days.ago

    trainers = {
      "events" => -> { sample_events(samples, since) },
      "transactions" => -> { sample_transactions(samples, since) },
      "spans" => -> { sample_spans(samples, since) }
    }

    trainers.each do |name, fetch|
      next if only && !only.include?(name)
      puts "[#{name}] sampling up to #{samples} rows from last #{days}d…"
      rows = fetch.call
      if rows.empty?
        puts "[#{name}] no rows found — skipping"
        next
      end
      train_dict(name, rows, dict_size, out_dir)
    end
  end

  def sample_events(n, since)
    Event.where("timestamp >= ?", since)
         .order(Arel.sql("RANDOM()"))
         .limit(n)
         .pluck(:payload)
         .compact
         .map { |p| p.is_a?(String) ? p : p.to_json }
  end

  def sample_transactions(n, since)
    Transaction.where("timestamp >= ?", since)
               .order(Arel.sql("RANDOM()"))
               .limit(n)
               .pluck(:tags, :measurements)
               .map { |tags, m| { tags: tags, measurements: m }.to_json }
  end

  # Spans live in ParquetLake (DuckDB-backed). Pull a random-ish sample by
  # ordering on a hash of span_id — RANDOM() over parquet is expensive.
  def sample_spans(n, since)
    sql = <<~SQL
      SELECT op, status, description, tags, data
      FROM #{DuckLake::Span.from_clause}
      WHERE timestamp >= ?
      ORDER BY hash(span_id)
      LIMIT #{n.to_i}
    SQL
    DuckLake::Span.query(sql, since).map do |r|
      {
        op: r["op"], status: r["status"], description: r["description"],
        tags: r["tags"], data: r["data"]
      }.to_json
    end
  rescue => e
    warn "[spans] ParquetLake unavailable (#{e.class}: #{e.message}) — skipping"
    []
  end

  def train_dict(name, samples, dict_size, out_dir)
    Dir.mktmpdir("zstd-train-#{name}-") do |dir|
      width = samples.size.to_s.length
      samples.each_with_index do |s, i|
        File.binwrite(File.join(dir, "s%0#{width}d.json" % i), s)
      end
      total_bytes = samples.sum(&:bytesize)
      puts "[#{name}] wrote #{samples.size} samples, #{total_bytes} bytes total"

      dict_path = out_dir.join("#{name}.dict").to_s
      ok = system("zstd", "--train", "--maxdict=#{dict_size}", "-o", dict_path,
                  *Dir[File.join(dir, "*.json")])
      raise "[#{name}] zstd --train failed" unless ok

      report_ratio(name, samples, dict_path)
    end
  end

  # Quick sanity check: compressed size with vs without the dict on a held-out
  # subset of the samples we just trained on (biased, but useful smoke signal).
  def report_ratio(name, samples, dict_path)
    require "zstd-ruby"
    dict = File.binread(dict_path)
    holdout = samples.sample([samples.size, 200].min)
    raw   = holdout.sum(&:bytesize)
    plain = holdout.sum { |s| Zstd.compress(s).bytesize }
    with  = holdout.sum { |s| Zstd.compress(s, dict: dict).bytesize }
    pct_plain = (100.0 * plain / raw).round(1)
    pct_dict  = (100.0 * with  / raw).round(1)
    puts "[#{name}] holdout(#{holdout.size}): raw=#{raw}B  zstd=#{plain}B (#{pct_plain}%)  zstd+dict=#{with}B (#{pct_dict}%)"
    puts "[#{name}] dict written to #{dict_path} (#{File.size(dict_path)} bytes)"
  rescue LoadError, NameError
    puts "[#{name}] dict written to #{dict_path} (#{File.size(dict_path)} bytes) — install zstd-ruby for ratio check"
  end
end

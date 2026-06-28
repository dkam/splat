# frozen_string_literal: true

# Spans compression spot-check.
#
#   bin/rails runner script/spans_compression_spotcheck.rb
#   SPANS_SAMPLE=8000 bin/rails runner script/spans_compression_spotcheck.rb
#
# Answers the one load-bearing question behind "blob the spans table": what
# realized compression ratio do real span trees get under a trained zstd dict?
# Mirrors Compression::DictTrainingJob (zstd --train --maxdict, Codec::LEVEL),
# serialising each transaction's tree in the shape a per-transaction blob would
# store, then measures the dict ratio on a DISJOINT held-out split — the same
# train/eval discipline the job uses, so the number is realized, not the dict's
# self-reported best case.
#
# Read-only. Trains a throwaway dict in a tmpdir; writes nothing to any DB.

require "open3"
require "tmpdir"

SAMPLE_TXNS = Integer(ENV.fetch("SPANS_SAMPLE", "4000"))
TRAIN_RATIO = 0.8
DICT_MAX_BYTES = Compression::DictTrainingJob::DICT_MAX_BYTES
LEVEL = Compression::Codec::LEVEL

def gb(bytes) = format("%.2f GB", bytes / 1024.0**3)
def mb(bytes) = format("%.1f MB", bytes / 1024.0**2)
def kb(bytes) = format("%.2f KB", bytes / 1024.0)

conn = TransactionsSpansRecord.connection

# ── 1. Stored-data window — measure it, don't assume it ──────────────────────
puts "=" * 72
puts "STORED DATA WINDOW  (transactions_spans DB)"
puts "=" * 72
%w[spans transactions].each do |table|
  row = conn.exec_query(<<~SQL).first
    SELECT COUNT(*) AS n,
           MIN(timestamp)  AS min_ts,  MAX(timestamp)  AS max_ts,
           MIN(created_at) AS min_cre, MAX(created_at) AS max_cre
      FROM #{table}
  SQL
  puts "\n#{table}: #{row["n"]} rows"
  puts "  timestamp : #{row["min_ts"]}  →  #{row["max_ts"]}"
  puts "  created_at: #{row["min_cre"]}  →  #{row["max_cre"]}"
end

# ── 2. On-disk now, straight from dbstat (what the dashboard shows) ───────────
puts "\n" + "=" * 72
puts "ON DISK NOW  (dbstat per btree)"
puts "=" * 72
begin
  rows = conn.exec_query(<<~SQL)
    SELECT name, SUM(pgsize) AS bytes FROM dbstat GROUP BY name ORDER BY bytes DESC
  SQL
  rows.each { |r| puts "  #{r["name"].ljust(48)} #{gb(r["bytes"].to_i)}" }
rescue => e
  puts "  (dbstat unavailable: #{e.class}: #{e.message})"
end

# ── 3. Sample transactions and rebuild their span trees ──────────────────────
# Uniform-random transactions, then ALL spans of each: the eval bytes end up
# weighted by tree size exactly as bytes sit on disk, so the ratio is unbiased
# for total storage (not skewed toward small trees).
puts "\n" + "=" * 72
puts "SAMPLING  (target #{SAMPLE_TXNS} transactions with spans)"
puts "=" * 72

ts_for = {}
# Group candidates by project_id so each Span lookup keys on the leading column
# of the (project_id, transaction_id, sequence) index — an index seek, not a
# 22M-row scan. transaction_id is a UUID, globally unique, so grouping the trees
# back together by it afterwards is unambiguous.
ids_by_project = Hash.new { |h, k| h[k] = [] }
Transaction
  .order(Arel.sql("RANDOM()"))
  .limit(SAMPLE_TXNS * 3)
  .pluck(:transaction_id, :timestamp, :project_id)
  .each { |id, ts, pid|
  ts_for[id] = ts
  ids_by_project[pid] << id
}

# Serialise one tree the way a per-transaction blob would: trace_id hoisted
# once (it's constant per tree), the per-span fields that vary kept inline.
# project_id/transaction_id are promoted columns, not blob bytes — excluded.
def tree_json(spans, trace_id)
  {
    trace_id: trace_id,
    spans: spans.map do |s|
      {
        span_id: s.span_id, parent_span_id: s.parent_span_id,
        op: s.op, status: s.status, description: s.description,
        ts: s.timestamp, end_ts: s.end_timestamp,
        depth: s.depth, sequence: s.sequence,
        tags: s.tags, data: s.data
      }
    end
  }.to_json
end

samples = []         # [{ ts:, json: }]
catch(:enough) do
  ids_by_project.each do |pid, ids|
    ids.each_slice(500) do |slice|
      Span.where(project_id: pid, transaction_id: slice)
        .order(:transaction_id, :sequence)
        .group_by(&:transaction_id).each do |txn_id, spans|
        next if spans.empty?
        samples << {ts: ts_for[txn_id], json: tree_json(spans, spans.first.trace_id)}
        throw :enough if samples.size >= SAMPLE_TXNS
      end
    end
  end
end

if samples.size < 200
  abort "Only #{samples.size} sampled trees — too few to train a dict. Is the spans table populated?"
end

raw_total = samples.sum { |s| s[:json].bytesize }
span_total = samples.sum { |s| JSON.parse(s[:json])["spans"].size }
puts "  trees sampled     : #{samples.size}"
puts "  spans in sample   : #{span_total}  (avg #{(span_total.to_f / samples.size).round(1)}/txn)"
puts "  raw JSON / tree   : #{kb(raw_total.to_f / samples.size)} (avg)"

# ── 4. Train a throwaway dict on 80%, measure on the held-out 20% ─────────────
shuffled = samples.shuffle(random: Random.new(42))
cut = (shuffled.size * TRAIN_RATIO).floor
train_set, eval_set = shuffled[0...cut], shuffled[cut..]

dict_bytes = Dir.mktmpdir("spans-train-") do |dir|
  train_set.each_with_index { |s, i| File.binwrite(File.join(dir, "s-#{i}.json"), s[:json]) }
  out = File.join(dir, "spans.dict")
  msg, status = Open3.capture2e("zstd", "--train", "--maxdict=#{DICT_MAX_BYTES}",
    "-o", out, *Dir[File.join(dir, "s-*.json")])
  raise "zstd --train failed: #{msg}" unless status.success?
  File.binread(out)
end

eval_raw = eval_set.sum { |s| s[:json].bytesize }
eval_plain = eval_set.sum { |s| Zstd.compress(s[:json], level: LEVEL).bytesize }
eval_dict = eval_set.sum { |s| Zstd.compress(s[:json], level: LEVEL, dict: dict_bytes).bytesize }

puts "\n" + "=" * 72
puts "COMPRESSION  (held-out eval set: #{eval_set.size} trees)"
puts "=" * 72
puts "  trained dict size : #{kb(dict_bytes.bytesize)}"
puts "  raw JSON          : #{mb(eval_raw)}"
puts "  plain zstd (L#{LEVEL})   : #{mb(eval_plain)}   #{(eval_raw.to_f / eval_plain).round(2)}×"
puts "  dict zstd  (L#{LEVEL})   : #{mb(eval_dict)}   #{(eval_raw.to_f / eval_dict).round(2)}×   ← realized"

# ── 5. Per-day drift — does the ratio hold across the data window? ────────────
puts "\n" + "=" * 72
puts "PER-DAY DICT RATIO  (held-out eval, by transaction day)"
puts "=" * 72
eval_set.group_by { |s| s[:ts]&.to_date }.sort_by { |d, _| d.to_s }.each do |day, group|
  raw = group.sum { |s| s[:json].bytesize }
  cmp = group.sum { |s| Zstd.compress(s[:json], level: LEVEL, dict: dict_bytes).bytesize }
  puts "  #{day}  n=#{group.size.to_s.rjust(4)}  #{(raw.to_f / cmp).round(2)}×"
end

# ── 6. Projection ────────────────────────────────────────────────────────────
dict_ratio = eval_raw.to_f / eval_dict
blob_per_txn = eval_dict.to_f / eval_set.size
txn_count = Transaction.count
projected_data = blob_per_txn * txn_count

puts "\n" + "=" * 72
puts "PROJECTION  (assumes every transaction gets one blob)"
puts "=" * 72
puts "  realized dict ratio   : #{dict_ratio.round(2)}×"
puts "  avg blob / txn        : #{kb(blob_per_txn)}"
puts "  transactions in DB    : #{txn_count}"
puts "  projected blob data   : ~#{gb(projected_data)}"
puts "  (+ a single transaction_id index; the ~4.4 GB of span indexes are reclaimed)"
puts
puts "CAVEATS: JSON only (msgpack untested — gap collapses post-dict). Throwaway"
puts "dict trained on THIS sample; a production segment dict retrained nightly may"
puts "do slightly better. Ratio is realized on held-out data, not the dict's"
puts "self-reported training-eval figure."

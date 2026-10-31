# frozen_string_literal: true

# Export one UTC day of logs into a standalone SQLite file, for the ADR 0005
# storage experiment (script/logs_blocks_experiment.rb builds and measures the
# candidate layouts from it, on another machine).
#
# Reads the logs database as it was before day files: run it on 1.28.x. Once
# logs are a file per day, LogsRecord's database is the catalog and this
# fails with "no such table: logs" — and a day's file under storage/log_days/
# is already what it exports.
#
#   bin/rails runner script/logs_day_export.rb
#   LOGS_DAY=2026-10-27 bin/rails runner script/logs_day_export.rb
#
# Against production, without shipping the script in an image (stdin runner):
#
#   ssh hetz01 'cd ~/booko-services/splat-booko && docker compose exec -T web bin/rails runner -' \
#     < script/logs_day_export.rb
#
# With no LOGS_DAY it picks the busiest of the last seven complete UTC days.
# Writes storage/exports/logs_<day>.sqlite3 (LOGS_EXPORT_PATH to override):
# the logs rows with their production schema (no indexes, no FTS), the
# compression dictionaries those rows reference, and an export_meta table.
#
# Read-only against the logs DB. Rows are read in id-range chunks, each its own
# short statement, so no read transaction stays open long enough to hold back a
# WAL checkpoint.

require "fileutils"
require "shellwords"

CHUNK = Integer(ENV.fetch("LOGS_EXPORT_CHUNK", "5000"))

def mb(bytes) = format("%.1f MB", bytes / 1024.0**2)

conn = LogsRecord.connection
day_bounds = ->(day) { ["#{day} 00:00:00", "#{day + 1} 00:00:00"] }
count_for = ->(day) {
  lo, hi = day_bounds.call(day)
  conn.select_value("SELECT COUNT(*) FROM logs WHERE timestamp >= #{conn.quote(lo)} AND timestamp < #{conn.quote(hi)}")
}

today = Time.now.utc.to_date
puts "Rows per UTC day (by timestamp):"
counts = (1..7).map { |n| today - n }.to_h { |d| [d, count_for.call(d)] }
counts.each { |d, n| puts "  #{d}  #{n.to_s.rjust(9)}" }

day = ENV["LOGS_DAY"] ? Date.iso8601(ENV["LOGS_DAY"]) : counts.max_by { |_, n| n }.first
expected = counts[day] || count_for.call(day)
lo_ts, hi_ts = day_bounds.call(day)
puts "\nExporting #{day}: #{expected} rows"
abort "Nothing to export." if expected.zero?

out = ENV.fetch("LOGS_EXPORT_PATH", Rails.root.join("storage", "exports", "logs_#{day}.sqlite3").to_s)
abort "#{out} already exists; remove it or set LOGS_EXPORT_PATH." if File.exist?(out)
FileUtils.mkdir_p(File.dirname(out))

# Rough guard against filling the volume: ~3 KB a row (production's logs table
# averages 2.7 KB of row data).
df = `df -Pk #{File.dirname(out).shellescape} 2>/dev/null`.lines.last.to_s.split
free = df[3].to_i * 1024
need = expected * 3 * 1024
puts "Free on #{File.dirname(out)}: #{mb(free)}; export needs about #{mb(need)}" if free.positive?
abort "Not enough free space." if free.positive? && free < need * 2

schema = ->(table) { conn.select_value("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = #{conn.quote(table)}") }
columns = conn.select_rows("PRAGMA table_info(logs)").map { |r| r[1] }
blob_columns = conn.select_rows("PRAGMA table_info(logs)").select { |r| r[2].to_s.upcase == "BLOB" }.map { |r| r[1] }

dest = SQLite3::Database.new(out)
dest.execute("PRAGMA journal_mode = OFF")
dest.execute("PRAGMA synchronous = OFF")
dest.execute(schema.call("logs"))
dest.execute(schema.call("compression_dictionaries"))
dest.execute("CREATE TABLE export_meta (key TEXT PRIMARY KEY, value TEXT)")

insert = dest.prepare("INSERT INTO logs (#{columns.join(", ")}) VALUES (#{(["?"] * columns.size).join(", ")})")
blob_idx = blob_columns.map { |c| columns.index(c) }

lo_id, hi_id = Log.id_bounds_for(Time.utc(day.year, day.month, day.day)...Time.utc((day + 1).year, (day + 1).month, (day + 1).day))
dict_ids = Set.new
exported = 0
chunks = 0
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

(lo_id..hi_id).step(CHUNK) do |from|
  to = [from + CHUNK - 1, hi_id].min
  rows = conn.select_rows(<<~SQL)
    SELECT #{columns.join(", ")} FROM logs
     WHERE id BETWEEN #{from} AND #{to}
       AND timestamp >= #{conn.quote(lo_ts)} AND timestamp < #{conn.quote(hi_ts)}
  SQL
  next if rows.empty?

  dest.transaction do
    rows.each do |row|
      vals = row.dup
      blob_idx.each { |i| vals[i] = SQLite3::Blob.new(vals[i]) if vals[i] }
      insert.execute(*vals)
    end
  end
  rows.each { |row| dict_ids << row[columns.index("dict_id")] if row[columns.index("dict_id")] }
  exported += rows.size
  chunks += 1

  if chunks % 20 == 0
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    puts format("  %9d / %d rows  (%.0fs)", exported, expected, elapsed)
  end
end
insert.close

dict_columns = conn.select_rows("PRAGMA table_info(compression_dictionaries)").map { |r| r[1] }
dict_insert = dest.prepare("INSERT INTO compression_dictionaries (#{dict_columns.join(", ")}) VALUES (#{(["?"] * dict_columns.size).join(", ")})")
unless dict_ids.empty?
  conn.select_rows("SELECT #{dict_columns.join(", ")} FROM compression_dictionaries WHERE id IN (#{dict_ids.to_a.join(", ")})").each do |row|
    vals = row.dup
    vals[dict_columns.index("dict")] = SQLite3::Blob.new(vals[dict_columns.index("dict")])
    dict_insert.execute(*vals)
  end
end
dict_insert.close

meta = {
  "day" => day.to_s,
  "exported_at" => Time.now.utc.iso8601,
  "rows" => exported,
  "source_id_range" => "#{lo_id}..#{hi_id}",
  "splat_version" => Splat::VERSION,
  "sqlite_version" => SQLite3::SQLITE_VERSION
}
meta.each { |k, v| dest.execute("INSERT INTO export_meta (key, value) VALUES (?, ?)", [k, v.to_s]) }
dest.close

elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts format("\nWrote %s: %d rows, %d dictionaries, %s, in %.0fs", out, exported, dict_ids.size, mb(File.size(out)), elapsed)
puts "Expected #{expected} rows; got #{exported}." if exported != expected

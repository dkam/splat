# frozen_string_literal: true

# Copies of the four databases that hold Splat's data. The cache and cable
# databases are left out: Splat rebuilds them.
#
# - snapshot: VACUUM INTO a directory, a compacted copy of each, consistent
#   as of the moment its copy began. Won't overwrite a copy already there.
# - sync: keeps a copy of each in a directory current. Where there's a copy to
#   update and sqlite3_rsync is installed, only the pages that changed are
#   written; otherwise it's a fresh VACUUM INTO.
#
# Both read the live databases while Splat runs. A copy is never consistent
# across databases — a few seconds apart, which a restore can live with (see
# README, Backup).
module DatabaseBackup
  class Exists < StandardError; end

  module_function

  def databases
    [ApplicationRecord, IssuesEventsRecord, TransactionsSpansRecord, LogsRecord].map do |record|
      config = record.connection_db_config
      {name: config.name, path: Rails.root.join(config.database)}
    end
  end

  def snapshot(dir, log: ->(_) {})
    dir = Pathname(dir)
    copies = databases.map { [it[:path], dir.join(it[:path].basename)] }
    existing = copies.map(&:last).select(&:exist?)
    raise Exists, "already there: #{existing.join(", ")}" if existing.any?

    dir.mkpath
    copies.each do |database, copy|
      timed(log, "#{database.basename}: VACUUM INTO #{copy}") { vacuum_into(database, copy) }
    end
  end

  def sync(dir, log: ->(_) {})
    dir = Pathname(dir)
    dir.mkpath
    rsync = rsync_path
    databases.each do |db|
      database = db[:path]
      copy = dir.join(database.basename)
      if copy.exist? && rsync
        timed(log, "#{database.basename}: sqlite3_rsync to #{copy}") do
          system(rsync, database.to_s, copy.to_s, exception: true)
        end
      else
        timed(log, "#{database.basename}: VACUUM INTO #{copy}") { vacuum_into(database, copy) }
      end
    end
  end

  def rsync_path
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { File.join(it, "sqlite3_rsync") }.find { File.executable?(it) }
  end

  # Written beside the copy and renamed over it, so a copy is never half
  # there. VACUUM INTO won't write over a file, and a -wal left by an earlier
  # sqlite3_rsync would be replayed into the new copy, so both go first.
  def vacuum_into(database, copy)
    partial = Pathname("#{copy}.partial")
    partial.delete if partial.exist?
    source = SQLite3::Database.new(database.to_s, readonly: true)
    source.busy_timeout = 5000
    source.execute("VACUUM INTO ?", [partial.to_s])
    %w[-wal -shm].each { |suffix| FileUtils.rm_f("#{copy}#{suffix}") }
    File.rename(partial, copy)
  ensure
    source&.close
  end

  def timed(log, what)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    log.call(format("%s (%.1fs)", what, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started))
  end
end

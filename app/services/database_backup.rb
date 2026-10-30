# frozen_string_literal: true

# Copies of the four databases that hold Splat's data, and of the logs day
# files (ADR 0005). The cache and cable databases are left out: Splat rebuilds
# them.
#
# - snapshot: VACUUM INTO a directory, a compacted copy of each, consistent
#   as of the moment its copy began. Won't overwrite a copy already there.
# - sync: keeps a copy of each in a directory current. Where there's a copy to
#   update and sqlite3_rsync is installed, only the pages that changed are
#   written; otherwise it's a fresh VACUUM INTO. A closed day file never
#   changes, so once copied after it closed it's skipped, as the legacy logs
#   database is once copied after its last write. The copy of a day file — or
#   of the legacy logs database — retention has deleted is deleted too.
#
# Day files go under logs/ in the directory, as they are under storage/. The
# legacy logs database, while it's there, is copied like the others.
#
# Both read the live databases while Splat runs. A copy is never consistent
# across databases — a few seconds apart, which a restore can live with (see
# README, Backup).
module DatabaseBackup
  class Exists < StandardError; end

  module_function

  # Each file to copy: name, path, where its copy goes in the backup
  # directory, and when it closed, after which a copy is current: a day file
  # two days after its day, the legacy logs database at its last write
  # (nothing writes it once day files take over). nil for the rest, which
  # change all the time.
  def databases
    main = [ApplicationRecord, IssuesEventsRecord, TransactionsSpansRecord, LogsCatalogRecord].map do |record|
      config = record.connection_db_config
      path = Rails.root.join(config.database)
      {name: config.name, path: path, copy: Pathname(path.basename), closed_at: nil}
    end
    main + Logs::DayFiles.shards.map do |shard|
      if shard.legacy?
        {name: "logs legacy", path: shard.path, copy: Pathname(shard.path.basename), closed_at: last_written(shard.path)}
      else
        {name: "logs #{shard.day.iso8601}", path: shard.path, copy: Pathname("logs").join(shard.path.basename),
         closed_at: (Time.utc(shard.day.year, shard.day.month, shard.day.day) + 2.days if shard.closed?)}
      end
    end
  end

  def snapshot(dir, log: ->(_) {})
    dir = Pathname(dir)
    copies = databases.map { [it[:path], dir.join(it[:copy])] }
    existing = copies.map(&:last).select(&:exist?)
    raise Exists, "already there: #{existing.join(", ")}" if existing.any?

    copies.each do |database, copy|
      copy.dirname.mkpath
      unless_deleted(database, log) do
        timed(log, "#{database.basename}: VACUUM INTO #{copy}") { vacuum_into(database, copy) }
      end
    end
  end

  def sync(dir, log: ->(_) {})
    dir = Pathname(dir)
    dir.mkpath
    rsync = rsync_path
    files = databases
    files.each do |db|
      database = db[:path]
      copy = dir.join(db[:copy])
      copy.dirname.mkpath
      next if db[:closed_at] && copy.exist? && copy.mtime >= db[:closed_at]

      unless_deleted(database, log) do
        if copy.exist? && rsync
          timed(log, "#{database.basename}: sqlite3_rsync to #{copy}") do
            system(rsync, database.to_s, copy.to_s, exception: true)
          end
        else
          timed(log, "#{database.basename}: VACUUM INTO #{copy}") { vacuum_into(database, copy) }
        end
        # An sqlite3_rsync with nothing to write leaves the mtime alone, and
        # the mtime is how the next sync knows this copy postdates the close.
        FileUtils.touch(copy) if db[:closed_at]
      end
    end
    # Without the day files' directory — a volume not mounted — a file
    # retention removed can't be told from one that isn't there to see.
    return unless Logs::DayFiles.root.directory?

    prune_day_files(dir.join("logs"), keep: files.map { dir.join(it[:copy]) }, log: log)
    prune_legacy(dir, log: log)
  end

  # The last write to a database, its -wal's included.
  def last_written(path)
    [path, Pathname("#{path}-wal")].select(&:exist?).map(&:mtime).max
  end

  # Retention deletes day files, and in time the legacy database, while a
  # backup runs: one gone between the listing and its copy is passed over.
  def unless_deleted(database, log)
    yield
  rescue SQLite3::Exception, RuntimeError, SystemCallError
    raise if database.exist?
    log.call("#{database.basename}: deleted by retention during the backup, skipped")
  end

  # The legacy logs database's copy, once retention has deleted the database.
  def prune_legacy(dir, log:)
    legacy = Logs::DayFiles.legacy_path
    return if legacy.nil? || legacy.exist?

    copy = dir.join(legacy.basename)
    return unless copy.exist?

    copy.delete
    log.call("#{copy.basename}: deleted, retention has removed it from Splat")
  end

  # Copies of day files that retention has since deleted.
  def prune_day_files(logs_dir, keep:, log:)
    return unless logs_dir.directory?

    logs_dir.children.each do |copy|
      next unless Logs::DayFiles::NAME.match?(copy.basename.to_s) && !keep.include?(copy)

      copy.delete
      log.call("#{copy.basename}: deleted, retention has removed it from Splat")
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

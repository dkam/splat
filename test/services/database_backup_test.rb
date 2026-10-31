# frozen_string_literal: true

require "test_helper"

class DatabaseBackupTest < ActiveSupport::TestCase
  setup do
    @dir = Pathname(Dir.mktmpdir("backup"))
  end

  teardown do
    FileUtils.rm_rf(@dir)
  end

  test "backs up the four databases that hold data, not the cache or cable" do
    assert_equal %w[primary issues_events transactions_spans logs], DatabaseBackup.databases.first(4).map { it[:name] }
  end

  # Fixtures are committed before each test's transaction, so they're what
  # another connection sees.
  test "a snapshot is a readable copy of each database" do
    DatabaseBackup.snapshot(@dir)

    assert_equal DatabaseBackup.databases.map { it[:copy].to_s }.sort,
      @dir.glob("**/*").select(&:file?).map { it.relative_path_from(@dir).to_s }.sort
    assert_includes rows(copy_of("primary"), "SELECT slug FROM projects"), [projects(:one).slug]
    assert_equal [["ok"]], rows(copy_of("issues_events"), "PRAGMA integrity_check")
  end

  test "a snapshot won't overwrite one already there" do
    DatabaseBackup.snapshot(@dir)
    before = copy_of("primary").mtime

    assert_raises(DatabaseBackup::Exists) { DatabaseBackup.snapshot(@dir) }
    assert_equal before, copy_of("primary").mtime
  end

  test "a sync starts a missing copy with VACUUM INTO" do
    DatabaseBackup.sync(@dir)

    assert_includes rows(copy_of("primary"), "SELECT slug FROM projects"), [projects(:one).slug]
  end

  # In place, so only the pages that changed are written.
  test "a sync brings an existing copy up to date with sqlite3_rsync" do
    skip "sqlite3_rsync isn't installed" unless DatabaseBackup.rsync_path
    DatabaseBackup.sync(@dir)
    inode = copy_of("primary").stat.ino

    with_probe_row do
      DatabaseBackup.sync(@dir)

      assert_equal [["after"]], rows(copy_of("primary"), "SELECT note FROM backup_probe")
      assert_equal inode, copy_of("primary").stat.ino, "the copy was replaced rather than synced"
    end
  end

  test "a sync without sqlite3_rsync replaces the copy with a fresh one" do
    with_stub(DatabaseBackup, :rsync_path, -> {}) do
      DatabaseBackup.sync(@dir)

      with_probe_row do
        DatabaseBackup.sync(@dir)

        assert_equal [["after"]], rows(copy_of("primary"), "SELECT note FROM backup_probe")
      end
    end
  end

  # Logs are a file per day (ADR 0005). A closed one never changes, so once
  # it's been copied after it closed, sync leaves it be.
  test "a sync copies day files under logs/, and skips a closed one already copied" do
    log = Log.create!(project_id: projects(:one).id, log_id: log_id_at(3.days.ago), timestamp: 3.days.ago,
      level: :info, source: "sentry", body: "x", payload: {})
    copy = @dir.join("logs", Logs::DayFiles.path_for(Logs::DayFiles.day_for(log.log_id)).basename)

    DatabaseBackup.sync(@dir)
    assert copy.exist?
    File.utime(copy.mtime, (Time.current - 1.minute).to_time, copy)
    copied_at = copy.mtime

    DatabaseBackup.sync(@dir)
    assert_equal copied_at, copy.mtime, "a closed day file copied after it closed is left alone"
  end

  test "a sync copies a closed day file again if its copy was made before it closed" do
    log = Log.create!(project_id: projects(:one).id, log_id: log_id_at(3.days.ago), timestamp: 3.days.ago,
      level: :info, source: "sentry", body: "x", payload: {})
    copy = @dir.join("logs", Logs::DayFiles.path_for(Logs::DayFiles.day_for(log.log_id)).basename)
    DatabaseBackup.sync(@dir)
    File.utime(copy.mtime, 3.days.ago.to_time, copy)

    DatabaseBackup.sync(@dir)
    assert_operator copy.mtime, :>, 1.minute.ago
  end

  # Huxley's review: sqlite3_rsync with nothing to change leaves the copy's
  # mtime alone, so a closed day file copied while it was open was synced
  # again every run.
  test "a closed day file synced once it closed isn't synced again" do
    log = Log.create!(project_id: projects(:one).id, log_id: log_id_at(3.days.ago), timestamp: 3.days.ago,
      level: :info, source: "sentry", body: "x", payload: {})
    copy = @dir.join("logs", Logs::DayFiles.path_for(Logs::DayFiles.day_for(log.log_id)).basename)
    copy.dirname.mkpath
    FileUtils.touch(copy)
    File.utime(3.days.ago.to_time, 3.days.ago.to_time, copy)
    rsync = @dir.join("fake_rsync")
    rsync.write("#!/bin/sh\nexit 0\n")
    rsync.chmod(0o755)

    with_stub(DatabaseBackup, :rsync_path, -> { rsync.to_s }) { DatabaseBackup.sync(@dir) }

    assert_operator copy.mtime, :>, 1.minute.ago, "marked as copied after it closed"
  end

  # Retention can delete a day file while a sync is part way through the list.
  test "a sync passes over a file deleted under it" do
    gone = {name: "logs 2020-01-01", path: Pathname("/nonexistent/2020-01-01.sqlite3"),
            copy: Pathname("logs/2020-01-01.sqlite3"), closed_at: Time.utc(2020, 1, 3)}
    real = DatabaseBackup.databases

    with_stub(DatabaseBackup, :databases, -> { [gone] + real }) do
      assert_nothing_raised { DatabaseBackup.sync(@dir) }
    end
    assert copy_of("primary").exist?, "the rest are still copied"
  end

  # The legacy logs database goes whole once it's past retention; its copy,
  # 59 GB on Booko, shouldn't outlive it.
  test "a sync deletes the copy of the legacy logs database once it's gone" do
    Logs::DayFiles.legacy_path = Pathname("/nonexistent/production_logs.sqlite3")
    Logs::DayFiles.root.mkpath
    stale = @dir.join("production_logs.sqlite3")
    FileUtils.touch(stale)

    DatabaseBackup.sync(@dir)

    refute stale.exist?
  ensure
    Logs::DayFiles.legacy_path = nil
  end

  # The code review: with storage/log_days missing — a volume not mounted —
  # every logs copy looked like one retention had removed.
  test "a sync leaves the logs copies alone when the day files aren't there" do
    day_copy = @dir.join("logs", "2020-01-01.sqlite3")
    day_copy.dirname.mkpath
    FileUtils.touch(day_copy)
    legacy_copy = @dir.join("production_logs.sqlite3")
    FileUtils.touch(legacy_copy)
    Logs::DayFiles.legacy_path = Pathname("/nonexistent/production_logs.sqlite3")

    with_stub(Logs::DayFiles, :root, -> { Pathname("/nonexistent/log_days") }) { DatabaseBackup.sync(@dir) }

    assert day_copy.exist?
    assert legacy_copy.exist?
  ensure
    Logs::DayFiles.legacy_path = nil
  end

  test "a sync deletes the copy of a day file retention has removed" do
    Logs::DayFiles.root.mkpath
    stale = @dir.join("logs", "2020-01-01.sqlite3")
    stale.dirname.mkpath
    FileUtils.touch(stale)
    unrelated = @dir.join("logs", "notes.txt")
    FileUtils.touch(unrelated)

    DatabaseBackup.sync(@dir)

    refute stale.exist?
    assert unrelated.exist?, "only day-file copies are pruned"
  end

  private

  def copy_of(name)
    @dir.join(DatabaseBackup.databases.find { it[:name] == name }[:path].basename)
  end

  def rows(path, sql)
    db = SQLite3::Database.new(path.to_s, readonly: true)
    db.execute(sql)
  ensure
    db&.close
  end

  # A row committed on its own connection, as a write after the first backup.
  def with_probe_row
    primary = DatabaseBackup.databases.find { it[:name] == "primary" }[:path].to_s
    db = SQLite3::Database.new(primary)
    db.busy_timeout = 5000
    db.execute("CREATE TABLE backup_probe (note TEXT)")
    db.execute("INSERT INTO backup_probe VALUES ('after')")
    yield
  ensure
    db&.execute("DROP TABLE IF EXISTS backup_probe")
    db&.close
  end
end

# The legacy logs database, registered as a shard while it's there. Its pool
# is dropped when a test lets go of it, which a test transaction pinned to it
# can't survive, so these run without one.
class DatabaseBackupLegacyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @dir = Pathname(Dir.mktmpdir("backup"))
    @legacy_dir = Pathname(Dir.mktmpdir("legacy"))
    @legacy = build_legacy_logs(@legacy_dir.join("production_logs.sqlite3"), rows: [
      {project_id: projects(:one).id, log_id: SecureRandom.uuid_v7, timestamp: 2.days.ago, body: "before day files"}
    ])
    Logs::DayFiles.legacy_path = @legacy
  end

  teardown do
    Logs::DayFiles.legacy_path = nil
    FileUtils.rm_rf(@dir)
    FileUtils.rm_rf(@legacy_dir)
  end

  # The code review: nothing writes the legacy database once day files take
  # over, but each sync copied it afresh — 59 GB on Booko, where the image's
  # SQLite has no sqlite3_rsync.
  test "a sync copies the legacy logs database again only once it has changed" do
    copy = @dir.join(@legacy.basename)
    DatabaseBackup.sync(@dir)
    assert copy.exist?

    copied = []
    DatabaseBackup.sync(@dir, log: ->(line) { copied << line if line.start_with?(@legacy.basename.to_s) })
    assert_empty copied, "unchanged since its copy"

    File.utime(Time.now + 60, Time.now + 60, @legacy)
    DatabaseBackup.sync(@dir, log: ->(line) { copied << line if line.start_with?(@legacy.basename.to_s) })
    assert_equal 1, copied.size, "changed after its copy"
  end
end

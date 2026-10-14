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
    assert_equal %w[primary issues_events transactions_spans logs], DatabaseBackup.databases.map { it[:name] }
  end

  # Fixtures are committed before each test's transaction, so they're what
  # another connection sees.
  test "a snapshot is a readable copy of each database" do
    DatabaseBackup.snapshot(@dir)

    assert_equal DatabaseBackup.databases.map { it[:path].basename.to_s }.sort, @dir.children.map { it.basename.to_s }.sort
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

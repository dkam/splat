# frozen_string_literal: true

require "test_helper"

class Logs::DayFilesTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  test "a UUIDv7 names the UTC day it was minted" do
    assert_equal Date.new(2026, 10, 28), Logs::DayFiles.day_for(log_id_at(Time.utc(2026, 10, 28, 23, 59, 59)))
    assert_equal Date.new(2026, 10, 29), Logs::DayFiles.day_for(log_id_at(Time.utc(2026, 10, 29, 0, 0, 0)))
    assert_nil Logs::DayFiles.day_for(SecureRandom.uuid), "a v4 UUID has no time in it"
    assert_nil Logs::DayFiles.day_for("not-a-uuid")
    assert_nil Logs::DayFiles.day_for(nil)
  end

  test "the first write of a day creates its file: WAL, the schema, a contentless index" do
    day = Time.now.utc.to_date - 5
    path = Logs::DayFiles.path_for(day)
    refute path.exist?

    Logs::DayFiles.write(day) { Log.create!(project_id: @project.id, log_id: log_id_at(5.days.ago), timestamp: 5.days.ago, level: :info, body: "x", payload: {}) }

    db = SQLite3::Database.new(path.to_s, readonly: true)
    assert_equal Logs::DayFiles::SCHEMA_VERSION, db.get_first_value("PRAGMA user_version")
    assert_equal "wal", db.get_first_value("PRAGMA journal_mode")
    assert_match(/content=''/, db.get_first_value("SELECT sql FROM sqlite_master WHERE name = 'logs_fts'"))
    assert_empty Dir.glob("#{path}.*.tmp*"), "the file is built aside and linked into place"
  ensure
    db&.close
  end

  # Two processes taking the day's first batch at once: the second link
  # fails, and the file the first made is the one both use.
  test "creating a day file someone else already made leaves theirs alone" do
    day = Time.now.utc.to_date - 6
    Logs::DayFiles.send(:create, day)
    raw = SQLite3::Database.new(Logs::DayFiles.path_for(day).to_s)
    raw.execute("INSERT INTO logs (project_id, timestamp, created_at) VALUES (1, '2026-01-01', '2026-01-01')")
    raw.close

    assert_nil Logs::DayFiles.send(:create, day)
    assert_equal 1, Logs::DayFiles.write(day) { Log.count }
  end

  # Huxley's review: some filesystems (Docker Desktop bind mounts among
  # them) have no hard links, and creating a day file needed one.
  test "a day file is created where hard links aren't supported" do
    day = Time.now.utc.to_date - 7

    with_stub(File, :link, ->(*) { raise Errno::EPERM, "link" }) do
      Logs::DayFiles.write(day) { Log.count }
    end

    assert Logs::DayFiles.path_for(day).file?
  end

  test "shards are newest day first" do
    [3.days.ago, Time.current, 1.day.ago].each do |at|
      Log.create!(project_id: @project.id, log_id: log_id_at(at), timestamp: at, level: :info, body: "x", payload: {})
    end
    today = Time.now.utc.to_date
    days = Logs::DayFiles.shards.map(&:day)

    assert_equal days.sort.reverse, days
    assert_equal [today, today - 1, today - 3], days & [today, today - 1, today - 3]
  end

  test "a day file closes an hour after its day ends" do
    today = Time.now.utc.to_date
    shard = ->(day) { Logs::DayFiles::Shard.new(name: :x, day: day, path: nil) }

    travel_to(today.in_time_zone("UTC") + 30.minutes) do
      refute shard.call(today).closed?
      refute shard.call(today - 1).closed?, "a job under way at midnight may still write it"
      assert shard.call(today - 2).closed?
    end
    travel_to(today.in_time_zone("UTC") + 2.hours) do
      refute shard.call(today).closed?
      assert shard.call(today - 1).closed?
    end
  end
end

# Deleting files under a test transaction's pinned connection can't be rolled
# back, so these run without one.
class Logs::DayFilesDeleteTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Retention in another process deleted it: this one lets go of the file the
  # next time it lists shards, and a stale handle on it can't bring it back as
  # an empty file.
  test "a day file deleted elsewhere is dropped, never recreated empty" do
    log = Log.create!(project_id: projects(:one).id, log_id: log_id_at(3.days.ago), timestamp: 3.days.ago,
      level: :info, body: "x", payload: {})
    stale = Logs::DayFiles.shard_for_log_id(log.log_id)
    stale.with { LogsRecord.connection_pool.disconnect! }

    FileUtils.rm_f(stale.path)

    # Its pool is still registered here: the next connection opens afresh.
    assert_raises(ActiveRecord::ActiveRecordError) { stale.with { Log.count } }
    refute stale.path.exist?, "a connection opened after the delete created the file again"
    refute_includes Logs::DayFiles.shards.map(&:name), stale.name
  end

  # Huxley's review: the maintenance consumer runs jobs with no executor
  # around them, so a lease taken on a day file by one job (the hourly storage
  # stats) was still held when retention, on the same thread, deleted the
  # file. Its pool looked in use and was kept, and the deleted file's space
  # never came back while the worker ran.
  test "a thread that read a day file still lets go of it when retention deletes it" do
    log = Log.create!(project_id: projects(:one).id, log_id: log_id_at(20.days.ago), timestamp: 20.days.ago,
      level: :info, body: "x", payload: {})
    shard = Logs::DayFiles.shard_for_log_id(log.log_id)
    StorageStats.file_bytes_total
    StorageStats.data_span

    Maintenance::RetentionJob.new.send(:retire_logs, 14.days.ago)

    refute shard.path.exist?
    assert_nil ActiveRecord::Base.connection_handler.retrieve_connection_pool("LogsRecord", role: :writing, shard: shard.name),
      "the deleted file's pool is still open"
    if File.directory?("/proc/self/fd")
      targets = Dir.glob("/proc/self/fd/*").filter_map do |fd|
        File.readlink(fd)
      rescue Errno::ENOENT
        nil # closed between the listing and the readlink
      end
      open_on_it = targets.grep(/#{Regexp.escape(shard.path.to_s)}/)
      assert_empty open_on_it, "a descriptor still holds the deleted file"
    end
  end

  test "delete! removes the file and its WAL" do
    log = Log.create!(project_id: projects(:one).id, log_id: log_id_at(3.days.ago), timestamp: 3.days.ago,
      level: :info, body: "x", payload: {})
    shard = Logs::DayFiles.shard_for_log_id(log.log_id)

    Logs::DayFiles.delete!(shard)

    assert_empty Dir.glob("#{shard.path}*")
    assert_nil Logs::Reader.find_by_log_id(log.log_id)
  end
end

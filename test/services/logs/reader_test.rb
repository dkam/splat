# frozen_string_literal: true

require "test_helper"

class Logs::ReaderTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  # ingested_at picks the day file; timestamp is the log's own time.
  def create_log(ingested_at: Time.current, timestamp: ingested_at, **extra)
    Log.create!(project_id: @project.id, log_id: log_id_at(ingested_at), timestamp: timestamp,
      level: :info, source: "sentry", body: "a line", payload: {}, **extra)
  end

  # The day files each statement in the block ran against.
  def files_queried(pattern = /FROM "logs"/)
    files = []
    callback = ->(*, payload) {
      next unless payload[:sql].match?(pattern) && !payload[:sql].match?(/MIN\(|MAX\(/)
      files << File.basename(payload[:connection].pool.db_config.database)
    }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    files
  end

  test "lists newest first across day files" do
    create_log(ingested_at: 2.days.ago, body: "two days ago")
    create_log(ingested_at: 1.hour.ago, body: "an hour ago")
    create_log(ingested_at: 1.day.ago, body: "yesterday")

    assert_equal ["an hour ago", "yesterday", "two days ago"], Logs::Reader.list(limit: 10) { Log.all }.map(&:body)
    assert_equal ["two days ago", "yesterday", "an hour ago"],
      Logs::Reader.list(limit: 10, oldest_first: true) { Log.all }.map(&:body)
  end

  # Ingest-day files overlap in time: a log ingested today can carry
  # yesterday's timestamp, and has to sort among yesterday's.
  test "merges by timestamp, not by file" do
    create_log(ingested_at: 1.day.ago, timestamp: 1.day.ago, body: "yesterday, on time")
    create_log(ingested_at: 1.minute.ago, timestamp: 1.day.ago - 1.hour, body: "yesterday, ingested late")
    create_log(ingested_at: 1.minute.ago, timestamp: 1.minute.ago, body: "today")

    assert_equal ["today", "yesterday, on time", "yesterday, ingested late"],
      Logs::Reader.list(limit: 10) { Log.all }.map(&:body)
  end

  test "pages across files with offset and limit" do
    5.times { |i| create_log(ingested_at: 1.day.ago - i.minutes, body: "yesterday #{i}") }
    5.times { |i| create_log(ingested_at: Time.current - i.minutes, body: "today #{i}") }

    page2 = Logs::Reader.list(limit: 4, offset: 4) { Log.all }.map(&:body)

    assert_equal ["today 4", "yesterday 0", "yesterday 1", "yesterday 2"], page2
  end

  test "stops once the page is full and the older files can't contribute" do
    3.times { |i| create_log(ingested_at: 3.days.ago - i.minutes, body: "old #{i}") }
    3.times { |i| create_log(ingested_at: Time.current - i.minutes, body: "new #{i}") }

    files = files_queried { assert_equal 2, Logs::Reader.list(limit: 2) { Log.all }.size }

    assert_equal [Logs::DayFiles.path_for(Time.now.utc.to_date).basename.to_s], files.uniq
  end

  # A window opens only the files whose timestamps can meet it.
  test "skips files whose timestamps fall outside within:" do
    create_log(ingested_at: 3.days.ago, body: "old")
    create_log(ingested_at: 1.minute.ago, body: "new")
    window = 1.hour.ago..Time.current

    files = files_queried do
      assert_equal ["new"], Logs::Reader.list(limit: 10, within: window) { Log.where(timestamp: window) }.map(&:body)
      assert_equal 1, Logs::Reader.count(within: window) { Log.where(timestamp: window) }
    end

    assert_equal [Logs::DayFiles.path_for(Time.now.utc.to_date).basename.to_s], files.uniq
  end

  # Huxley's review: bounds read while a file was open were kept once it
  # closed, so logs taken in after that read fell outside them for good.
  test "bounds read while a file was open aren't kept once it closes" do
    create_log(timestamp: 1.hour.ago, body: "early")
    Logs::Reader.list(limit: 1) { Log.all }
    late = create_log(body: "late")
    window = (late.timestamp - 1.minute)..(late.timestamp + 1.minute)

    travel 3.days do
      assert_equal ["late"], Logs::Reader.list(limit: 10, within: window) { Log.where(timestamp: window) }.map(&:body)
    end
  end

  test "a late log is found by a window on its own timestamp" do
    late = create_log(ingested_at: 1.minute.ago, timestamp: 2.days.ago, body: "late")
    window = (2.days.ago - 1.hour)..(2.days.ago + 1.hour)

    assert_equal [late.log_id], Logs::Reader.list(limit: 10, within: window) { Log.where(timestamp: window) }.map(&:log_id)
  end

  test "searches each file's index" do
    create_log(ingested_at: 2.days.ago, body: "checkout failed early")
    create_log(ingested_at: 1.minute.ago, body: "checkout failed again")
    create_log(ingested_at: 1.minute.ago, body: "checkout fine")

    assert_equal ["checkout failed again", "checkout failed early"],
      Logs::Reader.list(limit: 10) { Log.search_text("checkout failed") }.map(&:body)
  end

  test "counts and grouped counts sum across files" do
    create_log(ingested_at: 2.days.ago, level: :error, trace_id: "t1")
    create_log(ingested_at: 1.day.ago, level: :error, trace_id: "t1")
    create_log(ingested_at: 1.minute.ago, level: :info, trace_id: "t1")

    assert_equal 3, Logs::Reader.count { Log.where(trace_id: "t1") }
    assert_equal({"error" => 2, "info" => 1}, Logs::Reader.group_count { Log.where(trace_id: "t1").group(:level) })
  end

  test "finds a log by log_id, in whichever file it is" do
    log = create_log(ingested_at: 2.days.ago, body: "find me")
    create_log(ingested_at: 1.minute.ago)

    assert_equal "find me", Logs::Reader.find_by_log_id(log.log_id).body
    assert_nil Logs::Reader.find_by_log_id(log.log_id) { |logs| logs.where(project_id: -1) }
    assert_nil Logs::Reader.find_by_log_id(SecureRandom.uuid_v7)
    assert_nil Logs::Reader.find_by_log_id(nil)
  end

  # Pagy's countless paginator calls offset, limit and to_a, and nothing else.
  test "a Page takes offset and limit like a relation" do
    5.times { |i| create_log(ingested_at: Time.current - i.minutes, body: "line #{i}") }

    page = Logs::Reader::Page.new { Log.all }.offset(2).limit(2)

    assert_equal ["line 2", "line 3"], page.to_a.map(&:body)
  end

  test "no day files, no logs" do
    assert_empty Logs::Reader.list(limit: 10) { Log.all }
    assert_equal 0, Logs::Reader.count { Log.all }
  end
end

# A file retention deletes in another process while this one reads. Deleting
# files can't happen under a test transaction's pinned connections, so these
# run without one.
class Logs::ReaderDeletedFileTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def create_log(ingested_at:, body:)
    Log.create!(project_id: projects(:one).id, log_id: log_id_at(ingested_at), timestamp: ingested_at,
      level: :info, source: "sentry", body: body, payload: {})
  end

  # Listed just before the delete, read just after: the file is gone, and so
  # are its logs, which is what retention meant. Not an error.
  test "a file deleted between listing and reading is passed over" do
    create_log(ingested_at: 3.days.ago, body: "about to go")
    create_log(ingested_at: Time.current, body: "staying")
    listed = Logs::DayFiles.shards
    gone = listed.find { it.day == 3.days.ago.utc.to_date }
    gone.with { LogsRecord.connection_pool.disconnect! }
    FileUtils.rm_f(gone.path)

    with_stub(Logs::DayFiles, :shards, -> { listed }) do
      assert_equal ["staying"], Logs::Reader.list(limit: 10) { Log.all }.map(&:body)
      assert_equal 1, Logs::Reader.count { Log.all }
    end
  end

  # On Linux a deleted file stays whole for whoever has it open. Dropping the
  # file's pool would close that connection under its read — after waiting
  # out the checkout timeout, twice over, for it to be returned.
  test "a file deleted elsewhere keeps serving a read already using it" do
    log = create_log(ingested_at: 3.days.ago, body: "mid-read")
    shard = Logs::DayFiles.shard_for_log_id(log.log_id)
    conn = shard.with { LogsRecord.connection_pool.checkout }
    FileUtils.rm_f(shard.path)

    lister = Thread.new { Logs::DayFiles.shards }
    assert lister.join(2), "listing shards waited on the connection in use"
    assert_equal 1, conn.select_value("SELECT COUNT(*) FROM logs")
  ensure
    conn&.pool&.checkin(conn)
    lister&.join
  end
end

# The legacy logs database, read as one more file while it ages out. Its pool
# is dropped when a test lets go of it, which a test transaction pinned to it
# can't survive, so these run without one.
class Logs::ReaderLegacyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @project = projects(:one)
    @dir = Pathname(Dir.mktmpdir("legacy"))
  end

  teardown do
    Logs::DayFiles.legacy_path = nil
    FileUtils.rm_rf(@dir)
  end

  test "reads, searches and finds logs in the legacy database beside the day files" do
    legacy_id = SecureRandom.uuid_v7
    Logs::DayFiles.legacy_path = build_legacy_logs(@dir.join("logs.sqlite3"), rows: [
      {project_id: @project.id, log_id: legacy_id, timestamp: 2.days.ago, body: "from before day files",
       attrs_text: "order_status shipped", trace_id: "t1"}
    ])
    Log.create!(project_id: @project.id, timestamp: Time.current, level: :info, source: "sentry",
      body: "from a day file", trace_id: "t1", payload: {})

    assert_equal ["from a day file", "from before day files"], Logs::Reader.list(limit: 10) { Log.all }.map(&:body)
    assert_equal ["from before day files"], Logs::Reader.list(limit: 10) { Log.search_text("order_status:shipped") }.map(&:body)
    assert_equal 2, Logs::Reader.count { Log.where(trace_id: "t1") }
    assert_equal "from before day files", Logs::Reader.find_by_log_id(legacy_id).body
    assert_equal "from before day files", Logs::Reader.find_in_legacy(1).body
  end

  # A file at the legacy path that holds no logs — the 0-byte file SQLite
  # leaves when something opens a missing path, or a stub with only the FTS
  # tables — isn't a logs database, and mustn't fail every read.
  test "a legacy path with no logs table in it is passed over" do
    stub = @dir.join("logs.sqlite3")
    db = SQLite3::Database.new(stub.to_s)
    db.execute("CREATE VIRTUAL TABLE logs_fts USING fts5(body, attrs_text, content='logs', content_rowid='id')")
    db.close
    Logs::DayFiles.legacy_path = stub
    Log.create!(project_id: @project.id, timestamp: Time.current, level: :info, source: "sentry", body: "from a day file", payload: {})

    assert_equal ["from a day file"], Logs::Reader.list(limit: 10) { Log.all }.map(&:body)
    assert_empty Logs::DayFiles.shards.select(&:legacy?)
  end

  test "find_in_legacy is nil once there's no legacy database" do
    assert_nil Logs::Reader.find_in_legacy(1)
  end
end

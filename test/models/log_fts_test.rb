require "test_helper"

# Full-text search over body + attrs_text via the logs_fts FTS5 index.
class LogFtsTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  def create_log(body:, attrs_text: nil, **extra)
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "sentry", body: body, attrs_text: attrs_text, **extra)
  end

  # logs_fts is external-content: querying it reads the `logs` table, so
  # count(*)/rowid on logs_fts say nothing about whether the index is populated.
  # Only logs_fts_docsize tracks indexed documents.
  test "an emptied index is invisible to logs_fts itself, visible in docsize" do
    create_log(body: "canary row")
    conn = LogsRecord.connection
    conn.execute("INSERT INTO logs_fts(logs_fts) VALUES('delete-all')")

    assert_equal 0, Log.search_text("canary").count, "search must be broken after delete-all"
    # The trap: both of these look perfectly healthy. count(*) on logs_fts just
    # counts the content table, so it tracks Log.count and never reaches zero
    # while any log exists — which is why the old `count(*).zero?` guard could
    # never fire.
    assert_equal Log.count, conn.select_value("SELECT count(*) FROM logs_fts").to_i
    assert_not_nil conn.select_value("SELECT rowid FROM logs_fts LIMIT 1")
    # The only honest signal.
    assert_nil conn.select_value("SELECT 1 FROM logs_fts_docsize LIMIT 1")
  end

  test "ensure! rebuilds the index when it is empty but logs exist" do
    # The state a fresh db:schema:load leaves behind: virtual table created,
    # never populated, logs rows already present.
    create_log(body: "orphaned row needing an index")
    LogsRecord.connection.execute("INSERT INTO logs_fts(logs_fts) VALUES('delete-all')")
    assert_equal 0, Log.search_text("orphaned").count

    Logs::Fts.ensure!

    assert_equal 1, Log.search_text("orphaned").count, "ensure! should have rebuilt the index"
  end

  test "ensure! leaves a populated index alone" do
    create_log(body: "already indexed row")
    before = LogsRecord.connection.select_value("SELECT count(*) FROM logs_fts_docsize").to_i

    Logs::Fts.ensure!

    assert_equal before, LogsRecord.connection.select_value("SELECT count(*) FROM logs_fts_docsize").to_i
    assert_equal 1, Log.search_text("indexed").count
  end

  test "ensure! is a no-op when there are no logs at all" do
    Log.delete_all
    LogsRecord.connection.execute("INSERT INTO logs_fts(logs_fts) VALUES('delete-all')")

    assert_nothing_raised { Logs::Fts.ensure! }
    assert_nil LogsRecord.connection.select_value("SELECT 1 FROM logs_fts_docsize LIMIT 1")
  end

  test "matches on message tokens (AND semantics), not unrelated rows" do
    hit = create_log(body: "payment gateway timeout")
    create_log(body: "healthcheck ok")

    assert_equal [hit.id], Log.search_text("payment timeout").pluck(:id)
    assert_empty Log.search_text("payment healthcheck").to_a, "AND of terms — no single row has both"
  end

  test "matches on flattened attribute key and value" do
    hit = create_log(body: "request done", attrs_text: "user_id 4242 db.system postgresql")

    assert_equal [hit.id], Log.search_text("4242").pluck(:id)
    assert_equal [hit.id], Log.search_text("user_id").pluck(:id)
    assert_equal [hit.id], Log.search_text("postgresql").pluck(:id)
  end

  test "delete keeps the index in sync (via trigger)" do
    log = create_log(body: "ephemeral line", attrs_text: "k v")
    assert_equal [log.id], Log.search_text("ephemeral").pluck(:id)

    Log.where(id: log.id).delete_all # bulk delete bypasses AR callbacks, trigger still fires
    assert_empty Log.search_text("ephemeral").to_a
  end

  test "key:value scopes the match to that attribute (phrase)" do
    hit = create_log(body: "imports", attrs_text: "controller ImportsController action create status 422 method POST")
    create_log(body: "projects", attrs_text: "controller ProjectsController action show status 200 method GET")

    assert_equal [hit.id], Log.search_text("status:422").pluck(:id)
    assert_equal [hit.id], Log.search_text("method:POST").pluck(:id)
    # 422 is scoped to the status field — the status:200 row is not returned by status:422
    refute_includes Log.search_text("status:422").pluck(:id), Log.find_by(body: "projects").id
  end

  test "key:value combines with bare terms (AND)" do
    hit = create_log(body: "boom imports", attrs_text: "status 422 method POST")
    create_log(body: "quiet imports", attrs_text: "status 422 method GET")

    assert_equal [hit.id], Log.search_text("status:422 boom").pluck(:id)
  end

  test "a UUID is indexed and searched as one collapsed token (exact match, no fragment match)" do
    uuid = "550e8400-e29b-41d4-a716-446655440000"
    hit = create_log(body: "request done", attrs_text: Logs::AttrsText.build({"request_id" => uuid}))

    # full UUID (hyphenated or not) matches the single stored token
    assert_equal [hit.id], Log.search_text(uuid).pluck(:id)
    assert_equal [hit.id], Log.search_text(uuid.delete("-")).pluck(:id)
    # a fragment no longer loosely matches — it's not a standalone token anymore
    assert_empty Log.search_text("e29b").to_a
  end

  test "punctuation/operators in the query never raise and just match tokens" do
    hit = create_log(body: "user_id=4242 failed")
    # Quotes/operators are stripped to tokens, so this matches rather than
    # injecting FTS syntax or raising.
    assert_equal [hit.id], Log.search_text('user_id="4242"').pluck(:id)
    # No usable terms → nil query → search_text is a no-op filter (returns all),
    # and must never raise.
    assert_nil Log.fts_query("   ")
    assert_nil Log.fts_query("()*:")
    assert_nothing_raised { Log.search_text("()*:").to_a }
  end

  # --- Windowed search (rowid-bounded FTS) -----------------------------------
  #
  # Reported from the Booko side 2026-09-12: `search_logs` over a 30-minute
  # window with a common term (`duration`) never returned, and took the rest of
  # the MCP tool surface down with it for ~20 minutes. The timestamp window
  # contributed nothing to the plan — SQLite materialised every rowid matching
  # the term across the whole table, did one random row fetch per match, then
  # sorted the lot in a temp B-tree before LIMIT could apply. No early exit.
  #
  # The fix bounds the FTS subquery by rowid. Bounds come from MIN(id)/MAX(id)
  # over the timestamp window itself, so they are exact by construction rather
  # than assuming id order tracks timestamp order.

  test "a windowed search bounds the FTS subquery by rowid" do
    create_log(body: "duration exceeded", timestamp: 30.minutes.ago)
    window = 2.hours.ago..Time.current
    sql = Log.where(timestamp: window).search_text("duration", within: window).to_sql

    assert_match(/logs_fts MATCH/, sql)
    assert_match(/rowid BETWEEN/, sql,
      "the FTS subquery must carry a rowid bound, or the timestamp window does nothing")
  end

  test "SQLite pushes the rowid bound into the FTS scan" do
    create_log(body: "duration exceeded", timestamp: 30.minutes.ago)
    window = 2.hours.ago..Time.current
    sql = Log.where(timestamp: window).search_text("duration", within: window).to_sql
    plan = LogsRecord.connection.select_all("EXPLAIN QUERY PLAN #{sql}").rows.flatten.join("\n")

    fts_line = plan.lines.find { |l| l.include?("logs_fts") }
    assert fts_line, "expected an FTS scan in the plan, got:\n#{plan}"
    # FTS5 reports accepted rowid constraints by appending < and/or > to its
    # index string (e.g. "VIRTUAL TABLE INDEX 0:M2><"). Without them the bound
    # is being applied after the fact and every match is still enumerated.
    assert_match(/VIRTUAL TABLE INDEX \S*[<>]/, fts_line,
      "FTS5 did not accept the rowid bound; plan was:\n#{plan}")
  end

  test "a windowed search loses no row whose id is out of step with its timestamp" do
    # Ids are assigned in ingest order, not timestamp order: a delayed OTLP
    # batch lands with an id far above rows that are newer by timestamp. The
    # bound must still cover it, or windowed search silently drops late data.
    inside_early = create_log(id: 1000, body: "duration exceeded early", timestamp: 30.minutes.ago)
    create_log(id: 1001, body: "duration exceeded ancient", timestamp: 5.hours.ago)
    inside_late = create_log(id: 5000, body: "duration exceeded late arrival", timestamp: 20.minutes.ago)

    window = 2.hours.ago..Time.current
    found = Log.where(timestamp: window).search_text("duration", within: window).pluck(:id)

    assert_equal [inside_early.id, inside_late.id].sort, found.sort
  end

  test "a windowed search agrees with the unwindowed one over the same rows" do
    create_log(body: "duration exceeded now", timestamp: 10.minutes.ago)
    create_log(body: "duration exceeded older", timestamp: 90.minutes.ago)
    create_log(body: "duration exceeded ancient", timestamp: 5.hours.ago)
    create_log(body: "unrelated line", timestamp: 10.minutes.ago)

    window = 2.hours.ago..Time.current
    bounded = Log.where(timestamp: window).search_text("duration", within: window).pluck(:id).sort
    unbounded = Log.where(timestamp: window).search_text("duration").pluck(:id).sort

    assert_equal unbounded, bounded
    assert_equal 2, bounded.size
  end

  test "a window containing no rows at all matches nothing" do
    create_log(body: "duration exceeded", timestamp: Time.current)
    empty = (10.days.ago..9.days.ago)

    assert_empty Log.where(timestamp: empty).search_text("duration", within: empty).to_a
  end

  test "within: is optional — an unwindowed search still works" do
    hit = create_log(body: "duration exceeded")

    assert_equal [hit.id], Log.search_text("duration").pluck(:id)
  end
end

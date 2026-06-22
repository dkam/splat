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
end

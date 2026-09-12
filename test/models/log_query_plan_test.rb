require "test_helper"

# Query-plan guards for the filters `search_logs` (and LogsController#index)
# layer on top of a timestamp window.
#
# Reported from the Booko side 2026-09-12, alongside the FTS pathology in
# log_fts_test.rb: `search_logs` with *no* full-text query at all — a 2-minute
# window, limit 15 — also timed out. Measured on production 2026-09-12 against
# the 109 GB logs DB, a `level: :error` search over a 30-minute window asking
# for 3 rows took 34.5 seconds and queued two ingest POSTs behind it for the
# duration.
#
# The cause is the same shape as the FTS bug wearing a different index. Given
# a bare single-column index on a low-cardinality column, SQLite costs
# `level = ?` as the selective term, scans every matching row across the whole
# retention window, fetches each one to test the timestamp, and sorts the lot
# in a temp B-tree — so LIMIT cannot exit early and the window contributes
# nothing:
#
#   SEARCH logs USING INDEX index_logs_on_level (level=?)
#   USE TEMP B-TREE FOR ORDER BY
#
# An index carrying the equality *and* the ordering column lets the range and
# the sort share one traversal. Note these only bite when `project` is absent:
# with a project_id the planner picks index_logs_on_project_id_and_timestamp
# and is fine either way, which is why the narrow project+level retry in the
# incident report came back in under a second.
class LogQueryPlanTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @window = 30.minutes.ago..Time.current
  end

  def create_log(**extra)
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "sentry", body: "a line", **extra)
  end

  def plan_for(relation)
    LogsRecord.connection.select_all("EXPLAIN QUERY PLAN #{relation.to_sql}").rows.flatten.join("\n")
  end

  # The two assertions are separate on purpose: a plan can avoid the temp
  # B-tree and still scan the whole table, and vice versa. Both must hold for
  # LIMIT to exit early.
  def assert_window_bounded(relation, label)
    plan = plan_for(relation)

    assert_match(/timestamp>\?/, plan,
      "#{label}: the timestamp window must bound the index scan, or the whole " \
      "retention window is walked. Plan was:\n#{plan}")
    refute_match(/USE TEMP B-TREE FOR ORDER BY/, plan,
      "#{label}: every matching row is being materialised and sorted before " \
      "LIMIT can apply. Plan was:\n#{plan}")
  end

  test "a level-filtered window is bounded by the window" do
    create_log(level: :error)

    assert_window_bounded(
      Log.where(timestamp: @window).recent.by_level("error").limit(3), "level"
    )
  end

  test "an environment-filtered window is bounded by the window" do
    create_log(environment: "production")

    assert_window_bounded(
      Log.where(timestamp: @window).recent.by_environment("production").limit(3), "environment"
    )
  end

  test "level and environment together are bounded by the window" do
    create_log(level: :error, environment: "production")

    assert_window_bounded(
      Log.where(timestamp: @window).recent.by_level("error").by_environment("production").limit(3),
      "level + environment"
    )
  end

  # These already planned correctly before the composite indexes existed —
  # they're here so a future index doesn't quietly become the "selective" term
  # and reintroduce the pathology on a path nobody is watching.
  test "filters that were already window-bounded stay that way" do
    create_log(service: "postgresql", logger_name: "Booko", server_name: "pg01")

    {
      "service" => Log.where(timestamp: @window).recent.by_service("postgresql"),
      "logger" => Log.where(timestamp: @window).recent.by_logger("Booko"),
      "server_name" => Log.where(timestamp: @window).recent.by_server_name("pg01"),
      "bare window" => Log.where(timestamp: @window).recent
    }.each { |label, rel| assert_window_bounded(rel.limit(3), label) }
  end

  test "a project-scoped filter is bounded by the window" do
    create_log(level: :error)

    assert_window_bounded(
      Log.where(timestamp: @window, project_id: @project.id).recent.by_level("error").limit(3),
      "project + level"
    )
  end

  # The composite indexes make the bare single-column ones redundant: a strict
  # prefix of a wider index earns nothing and gives the planner a worse option
  # to choose. On the production logs table they are not free — dropping them
  # is the point, not a side effect.
  test "the bare level and environment indexes are gone" do
    names = LogsRecord.connection.indexes(:logs).map(&:name)

    refute_includes names, "index_logs_on_level",
      "superseded by index_logs_on_level_and_timestamp"
    refute_includes names, "index_logs_on_environment",
      "superseded by index_logs_on_environment_and_timestamp"
  end
end

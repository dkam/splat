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
#
# Since ADR 0005 a query runs in one day file at a time, and a file holds a
# day, so the bare (timestamp) index bounds an unscoped window well enough and
# (level, timestamp) and (environment, timestamp) went. These plans are what
# Logs::DayFiles::SCHEMA's indexes are for.
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
    Logs::DayFiles.write(Time.now.utc.to_date) do
      LogsRecord.lease_connection.select_all("EXPLAIN QUERY PLAN #{relation.to_sql}").rows.flatten.join("\n")
    end
  end

  def refute_sorted(relation, label)
    plan = plan_for(relation)
    refute_match(/USE TEMP B-TREE FOR ORDER BY/, plan,
      "#{label}: every matching row is being materialised and sorted before " \
      "LIMIT can apply. Plan was:\n#{plan}")
    plan
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

  # The logs page with no window: the newest 50 of a project, and of a
  # project at one level. Each walks an index in order and stops at LIMIT.
  test "a project's newest logs, and its newest at a level, need no sort" do
    create_log(level: :error)

    plan = refute_sorted(Log.where(project_id: @project.id).recent.limit(51), "project")
    assert_match(/index_logs_on_project_id_and_timestamp/, plan)
    plan = refute_sorted(Log.where(project_id: @project.id).recent.by_level("error").limit(51), "project + level")
    assert_match(/index_logs_on_project_id_and_level_and_timestamp/, plan)
  end

  # A release is one deploy's band of a project's logs, and often not in the
  # newest files at all. Bound by project alone, the filter walks the whole of
  # every file newer than it: 114 ms warm and 3.3 s cold per day file for a
  # release with no rows, measured on Booko's 2026-10-26 (378k rows of one
  # project).
  test "a release filter seeks on the release, not every row of the project" do
    create_log(release: "1.2.3")

    plan = refute_sorted(Log.where(project_id: @project.id).recent.by_release("1.2.3").limit(51), "project + release")
    assert_match(/index_logs_on_project_id_and_release_and_timestamp/, plan)
  end

  test "a trace's logs are a seek on trace_id" do
    create_log(trace_id: "abc123")

    assert_match(/index_logs_on_trace_id/, plan_for(Log.where(project_id: @project.id, trace_id: "abc123")))
  end

  test "a day file has the indexes these plans rely on, and no others" do
    names = Logs::DayFiles.write(Time.now.utc.to_date) { LogsRecord.lease_connection.indexes(:logs).map(&:name) }

    assert_equal %w[
      index_logs_on_log_id
      index_logs_on_project_id_and_duration_ms
      index_logs_on_project_id_and_level_and_timestamp
      index_logs_on_project_id_and_release_and_timestamp
      index_logs_on_project_id_and_timestamp
      index_logs_on_timestamp
      index_logs_on_trace_id
    ], names.sort
  end
end

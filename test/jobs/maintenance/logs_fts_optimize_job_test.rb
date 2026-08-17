# frozen_string_literal: true

require "test_helper"

class Maintenance::LogsFtsOptimizeJobTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Fts Project", slug: "fts-project-#{SecureRandom.hex(4)}", public_key: SecureRandom.hex(8))
  end

  test "merges the FTS index after deletes and search still works" do
    doomed = Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: 1.hour.ago,
      level: :info, source: "sentry", body: "doomed entry", payload: {})
    kept = Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: 1.hour.ago,
      level: :info, source: "sentry", body: "surviving entry", payload: {})
    doomed.delete

    result = Maintenance::LogsFtsOptimizeJob.new.perform

    assert result, "job completed rather than rescuing"
    assert result.key?(:pages_before)
    assert result.key?(:pages_after)
    assert_operator result[:merge_steps], :>=, 1, "ran at least one merge step"
    refute result[:budget_exhausted], "a tiny index finishes well inside the budget"

    hits = LogsRecord.connection.select_values(
      "SELECT rowid FROM logs_fts WHERE logs_fts MATCH 'surviving'"
    )
    assert_equal [kept.id], hits
    assert_empty LogsRecord.connection.select_values(
      "SELECT rowid FROM logs_fts WHERE logs_fts MATCH 'doomed'"
    )
  end

  test "honours its time budget and reports the work as unfinished" do
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: 1.hour.ago,
      level: :info, source: "sentry", body: "budgeted entry", payload: {})

    # A zero-second budget must not run a single merge step — the loop checks the
    # deadline before working, which is what keeps a long index from being
    # rewritten in one transaction.
    result = Maintenance::LogsFtsOptimizeJob.new.perform(max_seconds: 0)

    assert_equal 0, result[:merge_steps]
    assert_equal 0, result[:pages_reclaimed]
    assert result[:budget_exhausted]

    # Search still works — a skipped merge is a no-op, not a broken index.
    assert_equal 1, LogsRecord.connection.select_values(
      "SELECT rowid FROM logs_fts WHERE logs_fts MATCH 'budgeted'"
    ).size
  end
end

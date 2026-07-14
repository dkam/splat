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

    hits = LogsRecord.connection.select_values(
      "SELECT rowid FROM logs_fts WHERE logs_fts MATCH 'surviving'"
    )
    assert_equal [kept.id], hits
    assert_empty LogsRecord.connection.select_values(
      "SELECT rowid FROM logs_fts WHERE logs_fts MATCH 'doomed'"
    )
  end
end

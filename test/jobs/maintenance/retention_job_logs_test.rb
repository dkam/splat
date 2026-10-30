# frozen_string_literal: true

require "test_helper"

# Logs retention deletes whole files (ADR 0005), and a file deleted under a
# connection a test transaction has pinned can't be rolled back at teardown,
# so these run without one: they write committed rows (gone with the files
# after each test), and call retire_logs on its own rather than the whole job.
class Maintenance::RetentionJobLogsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  CUTOFF_DAYS = 14

  setup do
    @project = projects(:one)
    @cutoff = CUTOFF_DAYS.days.ago
  end

  teardown { Logs::DayFiles.legacy_path = nil }

  # A file goes once the day it took logs in has ended before the cutoff,
  # whatever the timestamps inside it.
  test "logs day files past the cutoff are deleted whole, recent ones kept" do
    old = create_log_ingested(20.days.ago, timestamp: 20.days.ago, body: "old")
    edge = create_log_ingested(@cutoff + 1.hour, timestamp: 15.days.ago, body: "late, on the cutoff's day")
    recent = create_log_ingested(1.day.ago, timestamp: 1.day.ago, body: "recent")

    deleted = retire_logs

    refute day_file(old).exist?, "a day file past the cutoff is deleted"
    assert day_file(edge).exist?, "the cutoff's own day still has logs inside the window"
    assert day_file(recent).exist?
    assert_equal 1, deleted
    assert_equal ["late, on the cutoff's day", "recent"], Logs::Reader.list(limit: 10) { Log.all }.map(&:body).sort
  end

  test "the legacy logs database is left alone until its newest log is past the cutoff" do
    Dir.mktmpdir("legacy") do |dir|
      Logs::DayFiles.legacy_path = build_legacy_logs(Pathname(dir).join("logs.sqlite3"), rows: [
        {project_id: @project.id, timestamp: 20.days.ago, body: "aged out, but not deleted on its own"},
        {project_id: @project.id, timestamp: 2.days.ago, body: "the newest legacy log"}
      ])

      assert_equal 0, retire_logs
      assert Logs::DayFiles.legacy_path.exist?
      assert_equal 2, Logs::Reader.count { Log.all }, "no rows deleted from it either"
    ensure
      Logs::DayFiles.legacy_path = nil
    end
  end

  test "the legacy logs database is deleted whole once its newest log is past the cutoff" do
    Dir.mktmpdir("legacy") do |dir|
      path = build_legacy_logs(Pathname(dir).join("logs.sqlite3"), rows: [
        {project_id: @project.id, timestamp: 20.days.ago, body: "old"},
        {project_id: @project.id, timestamp: 16.days.ago, body: "the newest legacy log"}
      ])
      Logs::DayFiles.legacy_path = path

      assert_equal 2, retire_logs
      refute path.exist?
      assert_empty Logs::DayFiles.shards.select(&:legacy?)
    ensure
      Logs::DayFiles.legacy_path = nil
    end
  end

  private

  def retire_logs = Maintenance::RetentionJob.new.send(:retire_logs, @cutoff)

  # A log as ingest at `ingested_at` would store it: in that day's file.
  def create_log_ingested(ingested_at, timestamp:, body:)
    Log.create!(project_id: @project.id, log_id: log_id_at(ingested_at), timestamp: timestamp,
      level: :info, source: "sentry", body: body, payload: {})
  end

  def day_file(log) = Logs::DayFiles.path_for(Logs::DayFiles.day_for(log.log_id))
end

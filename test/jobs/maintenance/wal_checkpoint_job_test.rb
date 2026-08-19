# frozen_string_literal: true

require "test_helper"

class Maintenance::WalCheckpointJobTest < ActiveSupport::TestCase
  test "checkpoints every known database and reports frames" do
    results = Maintenance::WalCheckpointJob.new.perform

    assert_equal Maintenance::WalCheckpointJob::DATABASES.keys.sort, results.keys.sort
    results.each do |name, result|
      assert result, "#{name} returned a result"
      next if result.key?(:error)

      assert_includes [0, 1], result[:busy], "#{name} busy flag is 0 or 1"
      assert_operator result[:frames], :>=, 0
      assert_operator result[:ms], :>=, 0
    end
  end

  test "checkpoints only the named databases" do
    results = Maintenance::WalCheckpointJob.new.perform("logs")

    assert_equal ["logs"], results.keys
  end

  test "covers all 6 database connections, including cache and cable" do
    assert_equal %w[logs transactions_spans issues_events primary cache cable].sort,
      Maintenance::WalCheckpointJob::DATABASES.keys.sort
  end

  test "raises when a database checkpoint fails for a reason other than busy/locked contention" do
    conn = LogsRecord.connection

    with_stub(conn, :select_rows, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "no connection" }) do
      error = assert_raises(RuntimeError) do
        Maintenance::WalCheckpointJob.new.perform("logs")
      end
      assert_match(/logs/, error.message)
    end
  end

  test "skips an unknown database without raising" do
    results = Maintenance::WalCheckpointJob.new.perform("nope")

    assert_empty results
  end

  test "a write is durable in the main db after a truncate checkpoint" do
    project = Project.create!(name: "Wal Project", slug: "wal-project-#{SecureRandom.hex(4)}",
      public_key: SecureRandom.hex(8))
    log = Log.create!(project_id: project.id, log_id: SecureRandom.uuid_v7, timestamp: 1.hour.ago,
      level: :info, source: "sentry", body: "checkpoint me", payload: {})

    Maintenance::WalCheckpointJob.new.perform("logs")

    assert_equal "checkpoint me", Log.find(log.id).body
  end
end

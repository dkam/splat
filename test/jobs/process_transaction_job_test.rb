# frozen_string_literal: true

require "test_helper"

class ProcessTransactionJobTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Span Test", slug: "span-test", public_key: SecureRandom.hex(8))
    # Wipe any spans from prior runs of this transaction_id (DuckLake is shared across tests)
    @transaction_id = SecureRandom.uuid
  end

  def base_payload(spans:, transaction_id:)
    now = Time.current.to_f
    trace_id = SecureRandom.hex(16)
    root_span_id = SecureRandom.hex(8)
    {
      "type" => "transaction",
      "transaction" => "TestController#index",
      "platform" => "ruby",
      "environment" => "test",
      "release" => "test-release",
      "start_timestamp" => now,
      "timestamp" => now + 0.5,
      "contexts" => {
        "trace" => {
          "trace_id" => trace_id,
          "span_id" => root_span_id,
          "op" => "http.server",
          "status" => "ok"
        }
      },
      "spans" => spans.map { |s| s.merge("trace_id" => trace_id, "parent_span_id" => root_span_id) },
      "request" => { "method" => "GET", "url" => "/test" }
    }
  end

  test "writes spans to DuckLake including a synthetic root span" do
    now = Time.current.to_f
    payload = base_payload(transaction_id: @transaction_id, spans: [
      { "span_id" => SecureRandom.hex(8), "op" => "db.sql.active_record",
        "description" => "SELECT * FROM widgets WHERE id = 42",
        "start_timestamp" => now + 0.05, "timestamp" => now + 0.10 },
      { "span_id" => SecureRandom.hex(8), "op" => "view.process_action.action_controller",
        "description" => "widgets/show.html.erb",
        "start_timestamp" => now + 0.15, "timestamp" => now + 0.45 }
    ])

    ProcessTransactionJob.new.perform(transaction_id: @transaction_id, payload: payload, project: @project)

    txn = Transaction.find_by!(transaction_id: @transaction_id)
    rows = DuckLake::Span.for_transaction(@transaction_id, project_id: @project.id, near_timestamp: txn.timestamp)
    assert_equal 3, rows.size, "1 root + 2 children"
    assert_equal [0, 1, 1], rows.map { |r| r["depth"].to_i }
    assert_equal [0, 1, 2], rows.map { |r| r["sequence"].to_i }
    assert_equal ["http.server", "db.sql.active_record", "view.process_action.action_controller"], rows.map { |r| r["op"] }
  end

  test "normalizes SQL literals out of span descriptions" do
    now = Time.current.to_f
    payload = base_payload(transaction_id: @transaction_id, spans: [
      { "span_id" => SecureRandom.hex(8), "op" => "db.sql.active_record",
        "description" => "SELECT * FROM users WHERE email = 'alice@example.com' AND id = 42",
        "start_timestamp" => now + 0.01, "timestamp" => now + 0.02 }
    ])

    ProcessTransactionJob.new.perform(transaction_id: @transaction_id, payload: payload, project: @project)

    txn = Transaction.find_by!(transaction_id: @transaction_id)
    rows = DuckLake::Span.for_transaction(@transaction_id, project_id: @project.id, near_timestamp: txn.timestamp)
    db_span = rows.find { |r| r["op"] == "db.sql.active_record" }
    refute_includes db_span["description"], "alice@example.com"
    refute_includes db_span["description"], "42"
    assert_includes db_span["description"], "= ?"
  end

  test "caps spans at 1000 and flags the transaction" do
    now = Time.current.to_f
    spans = (1..1500).map do |i|
      { "span_id" => SecureRandom.hex(8), "op" => "db.sql.active_record",
        "description" => "SELECT * FROM widgets WHERE id = #{i}",
        "start_timestamp" => now + (i * 0.0005),
        "timestamp"       => now + (i * 0.0005) + 0.0001 }
    end
    payload = base_payload(transaction_id: @transaction_id, spans: spans)

    ProcessTransactionJob.new.perform(transaction_id: @transaction_id, payload: payload, project: @project)

    txn = Transaction.find_by!(transaction_id: @transaction_id)
    assert txn.spans_truncated, "spans_truncated should be true"
    n = ApplicationDucklakeRecord.query(
      "SELECT COUNT(*) AS n FROM spans WHERE transaction_id = ?", @transaction_id
    ).first["n"]
    assert_equal 1001, n, "1000 child cap + 1 synthetic root"
  end
end

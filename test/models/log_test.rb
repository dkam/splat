require "test_helper"

class LogTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
  end

  test "round-trips a compressed payload (plain zstd fallback when no dict)" do
    log = Log.create!(
      project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :error, source: "sentry", body: "boom",
      payload: {"body" => "boom", "attributes" => {"foo" => "bar"}}
    )

    reloaded = Log.find(log.id)
    assert_nil reloaded.dict_id, "no active logs dict seeded → plain zstd"
    refute_nil reloaded.payload_blob
    assert_equal "boom", reloaded.payload["body"]
    assert_equal({"foo" => "bar"}, reloaded.payload_attributes)
  end

  test "payload_attributes normalizes the OTLP array shape to a flat hash" do
    # OTLP stores attributes as an array of {key, value:<AnyValue>} objects,
    # unlike Sentry's {key => {value}} hash. Both must flatten the same way.
    log = Log.create!(
      project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "otlp", body: "connection received",
      payload: {"attributes" => [
        {"key" => "db.system", "value" => {"stringValue" => "postgresql"}},
        {"key" => "db.rows", "value" => {"intValue" => "42"}}
      ]}
    )

    assert_equal({"db.system" => "postgresql", "db.rows" => "42"}, Log.find(log.id).payload_attributes)
  end

  test "payload_attributes unwraps the Sentry value-wrapper shape" do
    log = Log.create!(
      project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "sentry", body: "x",
      payload: {"attributes" => {"sentry.environment" => {"value" => "production", "type" => "string"}}}
    )

    assert_equal({"sentry.environment" => "production"}, Log.find(log.id).payload_attributes)
  end

  test "level enum exposes the expected mapping" do
    assert_equal({"trace" => 0, "debug" => 1, "info" => 2, "warn" => 3, "error" => 4, "fatal" => 5}, Log.levels)
  end

  test "for_trace scope returns matching rows ordered by time" do
    t = "abc123def456"
    older = Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: 2.minutes.ago, level: :info, source: "sentry", body: "a", trace_id: t, payload: {})
    newer = Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: 1.minute.ago, level: :info, source: "sentry", body: "b", trace_id: t, payload: {})
    Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current, level: :info, source: "sentry", body: "c", trace_id: "other", payload: {})

    assert_equal [older.id, newer.id], Log.for_trace(t).pluck(:id)
  end

  test "uses an active dictionary when one is seeded for the segment" do
    # zstd accepts a raw-content dictionary (arbitrary bytes), enough to
    # exercise the dict write/read path without shelling out to `zstd --train`.
    dict_bytes = Array.new(20) { |i| %({"body":"log line #{i}","attributes":{"sentry.environment":"production"}}) }.join
    Compression::LogsDict.create!(segment: "logs", version: 1, dict: dict_bytes, trained_at: Time.current, active: true)
    Compression::DictStore.reset!

    log = Log.create!(project_id: @project.id, log_id: SecureRandom.uuid_v7, timestamp: Time.current,
      level: :info, source: "sentry", body: "log line 99",
      payload: {"body" => "log line 99", "attributes" => {"sentry.environment" => "production"}})

    reloaded = Log.find(log.id)
    refute_nil reloaded.dict_id, "should write with the active dict"
    assert_equal "log line 99", reloaded.payload["body"]
  ensure
    Compression::DictStore.reset!
  end
end

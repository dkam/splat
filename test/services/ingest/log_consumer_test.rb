require "test_helper"

class Ingest::LogConsumerTest < ActiveSupport::TestCase
  setup do
    @project = projects(:one)
    @consumer = Ingest::LogConsumer.new
  end

  test "build_row encodes payload and promotes columns" do
    rec = {
      timestamp: Time.current, level: Log.levels["error"], severity_number: 17,
      body: "kaboom", logger_name: "rails", trace_id: "t1", span_id: "s1",
      environment: "production", release: "9.9.9", server_name: "web-2",
      source: "sentry", payload: {"body" => "kaboom"}
    }

    row = @consumer.send(:build_row, @project, rec)

    assert_equal @project.id, row[:project_id]
    assert_equal "error", Log.levels.key(row[:level])
    assert_equal "kaboom", row[:body]
    assert_equal "t1", row[:trace_id]
    assert_equal "sentry", row[:source]
    refute_nil row[:log_id]
    refute_nil row[:payload_blob]
    assert_equal({"body" => "kaboom"}, Compression::Codec.decode_json(row[:payload_blob], db: :logs, dict_id: row[:dict_id]))
  end

  test "parse dispatches by format" do
    sentry = @consumer.send(:parse, "sentry", {"items" => [{"level" => "info", "body" => "x"}]})
    assert_equal 1, sentry.size
    assert_equal "sentry", sentry.first[:source]
  end

  test "inserting parsed records persists rows" do
    payload = {"items" => [
      {"timestamp" => Time.now.to_f, "level" => "info", "body" => "one", "trace_id" => "trace-x"},
      {"timestamp" => Time.now.to_f, "level" => "error", "body" => "two", "trace_id" => "trace-x"}
    ]}
    records = @consumer.send(:parse, "sentry", payload)
    rows = records.map { |r| @consumer.send(:build_row, @project, r) }

    assert_difference -> { Log.where(trace_id: "trace-x").count }, 2 do
      Log.insert_all!(rows)
    end
  end
end

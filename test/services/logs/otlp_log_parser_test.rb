require "test_helper"

class Logs::OtlpLogParserTest < ActiveSupport::TestCase
  def base_payload(record)
    {
      "resourceLogs" => [
        {
          "resource" => {"attributes" => [
            {"key" => "service.name", "value" => {"stringValue" => "postgres"}},
            {"key" => "deployment.environment", "value" => {"stringValue" => "production"}},
            {"key" => "service.version", "value" => {"stringValue" => "16.2"}},
            {"key" => "host.name", "value" => {"stringValue" => "db-1"}}
          ]},
          "scopeLogs" => [
            {"scope" => {"name" => "pg.scraper"}, "logRecords" => [record]}
          ]
        }
      ]
    }
  end

  test "parses an OTLP JSON record with hex trace ids" do
    rec = {
      "timeUnixNano" => "1742575930000000000",
      "severityNumber" => 9,
      "severityText" => "INFO",
      "body" => {"stringValue" => "connection received"},
      "traceId" => "5b8efff798038103d269b633813fc60c",
      "spanId" => "eee19b7ec3c1b174",
      "attributes" => [{"key" => "db.system", "value" => {"stringValue" => "postgresql"}}]
    }

    records = Logs::OtlpLogParser.parse(base_payload(rec))
    assert_equal 1, records.size
    r = records.first
    assert_equal Log.levels["info"], r[:level]
    assert_equal "connection received", r[:body]
    assert_equal "5b8efff798038103d269b633813fc60c", r[:trace_id]
    assert_equal "eee19b7ec3c1b174", r[:span_id]
    assert_equal "production", r[:environment]
    assert_equal "16.2", r[:release]
    assert_equal "db-1", r[:server_name]
    assert_equal "pg.scraper", r[:logger_name]
    assert_equal "otlp", r[:source]
    # resource + record attrs flattened for the FTS index
    assert_includes r[:attrs_text], "db.system"
    assert_includes r[:attrs_text], "postgresql"
  end

  test "recovers trace_id/span_id from a sqlcommenter traceparent in the body" do
    rec = {
      "timeUnixNano" => "1742575930000000000",
      "severityNumber" => 9,
      "body" => {"stringValue" => "SELECT * FROM books /*traceparent='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'*/"}
    }

    r = Logs::OtlpLogParser.parse(base_payload(rec)).first
    assert_equal "0af7651916cd43dd8448eb211c80319c", r[:trace_id]
    assert_equal "b7ad6b7169203331", r[:span_id]
  end

  test "prefers explicit OTLP trace fields over the body comment" do
    rec = {
      "traceId" => "5b8efff798038103d269b633813fc60c",
      "body" => {"stringValue" => "x /*traceparent='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'*/"}
    }
    r = Logs::OtlpLogParser.parse(base_payload(rec)).first
    assert_equal "5b8efff798038103d269b633813fc60c", r[:trace_id]
  end

  test "decodes base64-encoded trace ids (canonical OTLP/JSON)" do
    hex = "0af7651916cd43dd8448eb211c80319c"
    b64 = Base64.strict_encode64([hex].pack("H*"))
    r = Logs::OtlpLogParser.parse(base_payload({"traceId" => b64, "body" => {"stringValue" => "x"}})).first
    assert_equal hex, r[:trace_id]
  end

  test "rejects a base64 trace id that decodes to the wrong width" do
    # "AA==" decodes to a single 0x00 byte → "00", not a full 32-hex trace id.
    # A truncated id would never correlate to a real trace, so drop it instead.
    r = Logs::OtlpLogParser.parse(base_payload({"traceId" => "AA==", "body" => {"stringValue" => "x"}})).first
    assert_nil r[:trace_id]
  end

  test "maps severity_number ranges onto the level enum" do
    {1 => "trace", 5 => "debug", 9 => "info", 13 => "warn", 17 => "error", 21 => "fatal"}.each do |num, level|
      r = Logs::OtlpLogParser.parse(base_payload({"severityNumber" => num, "body" => {"stringValue" => "x"}})).first
      assert_equal Log.levels[level], r[:level], "severityNumber #{num} should map to #{level}"
    end
  end

  test "tolerates empty or non-hash payloads" do
    assert_equal [], Logs::OtlpLogParser.parse(nil)
    assert_equal [], Logs::OtlpLogParser.parse({})
    assert_equal [], Logs::OtlpLogParser.parse({"resourceLogs" => []})
  end
end

require "test_helper"

class Logs::SentryLogParserTest < ActiveSupport::TestCase
  test "parses a batch of records into normalized hashes" do
    payload = {
      "items" => [
        {
          "timestamp" => 1742575930.0,
          "level" => "info",
          "body" => "User logged in",
          "trace_id" => "5b8efff798038103d269b633813fc60c",
          "severity_number" => 9,
          "attributes" => {
            "sentry.environment" => {"value" => "production", "type" => "string"},
            "sentry.release" => {"value" => "1.2.3", "type" => "string"},
            "logger.name" => {"value" => "rails", "type" => "string"},
            "server.address" => {"value" => "web-1", "type" => "string"}
          }
        },
        {"timestamp" => 1742575931.0, "level" => "warning", "body" => "slow"}
      ]
    }

    records = Logs::SentryLogParser.parse(payload)

    assert_equal 2, records.size
    first = records.first
    assert_equal Log.levels["info"], first[:level]
    assert_equal "production", first[:environment]
    assert_equal "1.2.3", first[:release]
    assert_equal "rails", first[:logger_name]
    assert_equal "web-1", first[:server_name]
    assert_equal "5b8efff798038103d269b633813fc60c", first[:trace_id]
    assert_equal "sentry", first[:source]
    assert_equal payload["items"].first, first[:payload]
    assert_instance_of Time, first[:timestamp]
  end

  test "maps the 'warning' alias onto warn" do
    records = Logs::SentryLogParser.parse({"items" => [{"level" => "warning", "body" => "x"}]})
    assert_equal Log.levels["warn"], records.first[:level]
  end

  test "tolerates a missing or non-hash payload" do
    assert_equal [], Logs::SentryLogParser.parse(nil)
    assert_equal [], Logs::SentryLogParser.parse({})
    assert_equal [], Logs::SentryLogParser.parse({"items" => ["not a hash"]})
  end

  test "unknown level maps to nil rather than raising" do
    records = Logs::SentryLogParser.parse({"items" => [{"level" => "weird", "body" => "x"}]})
    assert_nil records.first[:level]
  end
end

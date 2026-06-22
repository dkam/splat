# frozen_string_literal: true

module Logs
  # Normalizes a Sentry "log" envelope item into an array of common log-record
  # hashes consumed by Ingest::LogConsumer. A single item carries a *batch* of
  # records under "items"; each record is OTLP-aligned:
  #
  #   { "timestamp": 1742575930.0, "level": "info", "body": "...",
  #     "trace_id": "...", "severity_number": 9,
  #     "attributes": { "sentry.environment": {"value": "production", ...}, ... } }
  #
  # Context (environment/release/server/logger) rides in `attributes` as
  # {value, type} objects, so we unwrap those and fall back across the keys
  # different SDK versions use.
  class SentryLogParser
    SOURCE = "sentry"

    def self.parse(payload) = new(payload).parse

    def initialize(payload)
      @payload = payload
    end

    def parse
      records = @payload.is_a?(Hash) ? Array(@payload["items"]) : []
      records.filter_map { |rec| normalize(rec) }
    end

    private

    def normalize(rec)
      return nil unless rec.is_a?(Hash)
      attrs = rec["attributes"] || {}

      {
        timestamp: parse_ts(rec["timestamp"]),
        level: Logs::Level.from_string(rec["level"]),
        severity_number: rec["severity_number"],
        body: rec["body"].to_s,
        logger_name: attr(attrs, "logger.name") || attr(attrs, "sentry.logger.name"),
        trace_id: rec["trace_id"] || attr(attrs, "sentry.trace.trace_id"),
        span_id: rec["span_id"] || attr(attrs, "sentry.trace.parent_span_id"),
        environment: attr(attrs, "sentry.environment"),
        release: attr(attrs, "sentry.release"),
        server_name: attr(attrs, "server.address") || attr(attrs, "sentry.server_name"),
        source: SOURCE,
        payload: rec
      }
    end

    # Sentry attribute values are {"value" => x, "type" => "string"} objects;
    # tolerate a bare scalar too.
    def attr(attrs, key)
      v = attrs[key]
      v.is_a?(Hash) ? v["value"] : v
    end

    def parse_ts(ts)
      case ts
      when Numeric then Time.at(ts).utc
      when String
        begin
          Time.parse(ts).utc
        rescue ArgumentError
          Time.current
        end
      else Time.current
      end
    end
  end
end

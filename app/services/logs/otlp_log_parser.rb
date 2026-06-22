# frozen_string_literal: true

module Logs
  # Normalizes an OTLP/HTTP **JSON** logs request into the common log-record
  # hashes consumed by Ingest::LogConsumer. Structure:
  #
  #   { "resourceLogs": [
  #       { "resource": { "attributes": [ {"key": "service.name", "value": {"stringValue": "pg"}} ] },
  #         "scopeLogs": [
  #           { "scope": {"name": "..."},
  #             "logRecords": [
  #               { "timeUnixNano": "1742575930000000000", "severityNumber": 9,
  #                 "severityText": "INFO", "body": {"stringValue": "..."},
  #                 "attributes": [...], "traceId": "...", "spanId": "..." } ] } ] } ] }
  #
  # Attribute/body values are OTLP AnyValue objects ({stringValue|intValue|...}).
  # Postgres has no native trace context, so when a record's traceId is empty we
  # recover it from a sqlcommenter `traceparent` comment in the body.
  class OtlpLogParser
    SOURCE = "otlp"

    # sqlcommenter embeds W3C traceparent: 00-<32 hex trace>-<16 hex span>-<flags>
    TRACEPARENT = /traceparent='?00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}'?/i

    def self.parse(payload) = new(payload).parse

    def initialize(payload)
      @payload = payload
    end

    def parse
      return [] unless @payload.is_a?(Hash)

      Array(@payload["resourceLogs"]).flat_map do |resource_log|
        resource_attrs = index_attributes(resource_log.dig("resource", "attributes"))
        Array(resource_log["scopeLogs"]).flat_map do |scope_log|
          scope_name = scope_log.dig("scope", "name")
          Array(scope_log["logRecords"]).filter_map do |rec|
            normalize(rec, resource_attrs, scope_name)
          end
        end
      end
    end

    private

    def normalize(rec, resource_attrs, scope_name)
      return nil unless rec.is_a?(Hash)
      attrs = index_attributes(rec["attributes"])
      body = any_value(rec["body"]).to_s

      trace_id = normalize_id(rec["traceId"], 32)
      span_id = normalize_id(rec["spanId"], 16)
      if trace_id.blank? && (m = body.match(TRACEPARENT))
        trace_id = m[1]
        span_id ||= m[2]
      end

      level = Logs::Level.from_otlp_number(rec["severityNumber"]) ||
        Logs::Level.from_string(rec["severityText"])

      {
        timestamp: parse_nanos(rec["timeUnixNano"] || rec["observedTimeUnixNano"]),
        level: level,
        severity_number: rec["severityNumber"],
        body: body,
        logger_name: attrs["log.logger"] || attrs["code.namespace"] || scope_name,
        trace_id: trace_id,
        span_id: span_id,
        environment: resource_attrs["deployment.environment"] || attrs["deployment.environment"],
        release: resource_attrs["service.version"],
        server_name: resource_attrs["host.name"] || resource_attrs["server.address"] || resource_attrs["service.name"],
        source: SOURCE,
        attrs_text: Logs::AttrsText.build(resource_attrs.merge(attrs)),
        payload: rec
      }
    end

    # Build a {key => scalar} map from an OTLP attributes array.
    def index_attributes(list)
      Array(list).each_with_object({}) do |kv, h|
        next unless kv.is_a?(Hash) && kv["key"]
        h[kv["key"]] = any_value(kv["value"])
      end
    end

    # Unwrap an OTLP AnyValue ({stringValue|intValue|boolValue|doubleValue|...}).
    def any_value(value)
      return value unless value.is_a?(Hash)
      return value["stringValue"] if value.key?("stringValue")
      return value["intValue"] if value.key?("intValue")
      return value["boolValue"] if value.key?("boolValue")
      return value["doubleValue"] if value.key?("doubleValue")
      # arrayValue/kvlistValue: keep the raw structure rather than guessing.
      value["arrayValue"] || value["kvlistValue"] || nil
    end

    # OTLP byte fields (trace/span ids) are base64 in canonical OTLP/JSON, but
    # many exporters send hex. Accept hex directly; otherwise base64-decode to
    # hex. expected_hex_len is the hex string length (32 for trace, 16 for span).
    def normalize_id(value, expected_hex_len)
      return nil if value.blank?
      s = value.to_s
      return s.downcase if s.length == expected_hex_len && s.match?(/\A[0-9a-f]+\z/i)
      begin
        decoded = Base64.decode64(s).unpack1("H*")
        # Only accept a decode that yields exactly the expected id width.
        # Otherwise a short/malformed value (e.g. "AA==" → "00") would be
        # stored truncated and never correlate to its real trace/span.
        decoded if decoded&.length == expected_hex_len
      rescue
        nil
      end
    end

    def parse_nanos(nanos)
      return Time.current if nanos.blank?
      Time.at(nanos.to_i / 1_000_000_000.0).utc
    rescue
      Time.current
    end
  end
end

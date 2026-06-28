# frozen_string_literal: true

class Span
  # A decoded span from a SpanTree blob (or mapped from a legacy AR Span row).
  # Presents the same interface every per-transaction reader used on the AR Span:
  # attribute readers, computed #duration_ms, string-key #[] access (the waterfall
  # view), and #attributes (the MCP handler). This lets Span.for_transaction return
  # one uniform type whether the data came from a blob or the legacy spans table.
  #
  # On-disk blob keys: trace_id is hoisted to the tree; timestamps use the shorter
  # "ts"/"end_ts" form (see Ingest::TransactionConsumer#build_span_tree). Those are
  # the ONLY place keys differ from the public field names, and they are translated
  # here — keep this in sync with build_span_tree.
  class Node
    def self.from_tree(tree)
      trace_id = tree["trace_id"]
      Array(tree["spans"]).map { |s| new(s, trace_id: trace_id) }.sort_by(&:sequence)
    end

    def self.from_record(span)
      new(
        {
          "span_id" => span.span_id, "parent_span_id" => span.parent_span_id,
          "op" => span.op, "status" => span.status, "description" => span.description,
          "ts" => span.timestamp, "end_ts" => span.end_timestamp,
          "depth" => span.depth, "sequence" => span.sequence,
          "tags" => span.tags, "data" => span.data
        },
        trace_id: span.trace_id
      )
    end

    def initialize(raw, trace_id:)
      @raw = raw
      @trace_id = trace_id
    end

    def span_id = @raw["span_id"]
    def parent_span_id = @raw["parent_span_id"]
    def op = @raw["op"]
    def status = @raw["status"]
    def description = @raw["description"]
    def depth = @raw["depth"].to_i
    def sequence = @raw["sequence"].to_i
    attr_reader :trace_id
    def tags = @raw["tags"] || {}
    def data = @raw["data"] || {}

    def timestamp = @timestamp ||= parse_time(@raw["ts"])
    def end_timestamp = @end_timestamp ||= parse_time(@raw["end_ts"])

    # Same formula as Span#duration_ms.
    def duration_ms
      return nil unless end_timestamp && timestamp
      ((end_timestamp - timestamp) * 1000).round
    end

    # String-key access used by the waterfall view (s["timestamp"].to_time,
    # s["op"], s["depth"], …). Timestamps come back as Time, the canonical
    # "timestamp"/"end_timestamp"/"duration_ms" keys resolve to the computed values.
    def [](key)
      case key.to_s
      when "timestamp" then timestamp
      when "end_timestamp" then end_timestamp
      when "duration_ms" then duration_ms
      when "trace_id" then trace_id
      when "depth" then depth
      when "sequence" then sequence
      when "tags" then tags
      when "data" then data
      else @raw[key.to_s]
      end
    end

    # String-keyed hash mirroring the columns the MCP handler reads; it merges
    # "duration_ms" in itself. Timestamps as Time, matching the old AR row.
    def attributes
      {
        "span_id" => span_id, "parent_span_id" => parent_span_id,
        "trace_id" => trace_id, "op" => op, "status" => status,
        "description" => description, "timestamp" => timestamp,
        "end_timestamp" => end_timestamp, "depth" => depth,
        "sequence" => sequence, "tags" => tags, "data" => data
      }
    end

    private

    def parse_time(value)
      case value
      when nil then nil
      when Time, ActiveSupport::TimeWithZone then value
      else Time.zone ? Time.zone.parse(value.to_s) : Time.parse(value.to_s)
      end
    end
  end
end

# frozen_string_literal: true

# A single structured log line — a flat, searchable time-series record (no
# fingerprint/grouping, unlike Issue). Lands from Sentry Logs (envelope item
# type "log") or OTLP (/v1/logs), both normalized into the same shape. The full
# record (including attributes) is zstd-compressed into payload_blob; the hot
# query/display fields are promoted to columns.
class Log < LogsRecord
  include Compression::CompressedJson

  compressed_json :payload, db: :logs, table: "logs", platform: :source

  # Sentry sends trace/debug/info/warn/error/fatal; OTLP severity numbers are
  # bucketed onto the same scale at parse time. Stored as an integer column.
  enum :level, {trace: 0, debug: 1, info: 2, warn: 3, error: 4, fatal: 5}

  # project lives on the primary DB. belongs_to still resolves `log.project`
  # via a separate SELECT, but Rails won't generate a cross-DB JOIN — so avoid
  # `.includes(:project)` here (same constraint as Event).
  belongs_to :project

  scope :recent, -> { order(timestamp: :desc) }
  scope :for_trace, ->(trace_id) { where(trace_id: trace_id).order(:timestamp) }
  scope :by_level, ->(level) { where(level: level) }
  scope :by_logger, ->(name) { where(logger_name: name) }
  scope :by_environment, ->(env) { where(environment: env) }
  scope :in_range, ->(range) { range ? where(timestamp: range) : all }
  # Free-text search over message body + flattened attributes via the logs_fts
  # FTS5 index (see config/initializers/logs_fts.rb). Falls back to all when the
  # query has no usable terms.
  scope :search_text, ->(text) {
    q = fts_query(text)
    q ? where("logs.id IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)", q) : all
  }

  # Turn free user input into a safe FTS5 MATCH expression: extract word tokens
  # and AND them as quoted phrases, so punctuation/operators in the input can't
  # break the query or inject FTS syntax. Returns nil when there's nothing to
  # search.
  def self.fts_query(text)
    terms = text.to_s.scan(/[\p{Alnum}_]+/)
    return nil if terms.empty?
    terms.map { |t| %("#{t}") }.join(" ")
  end

  # Attributes for display, normalized to a flat {key => scalar} hash whatever
  # the source (lazy; only decompresses the blob on access). Sentry stores
  # attributes as a {key => {"value"=>x}} hash; OTLP stores an array of
  # {"key"=>k, "value"=><AnyValue>} objects. Both are flattened here so the show
  # view and MCP can iterate uniformly — iterating the OTLP array as a hash
  # otherwise yields the {key,value} object as the key and a blank value.
  def payload_attributes
    raw = payload&.dig("attributes")
    case raw
    when Array
      raw.each_with_object({}) do |kv, h|
        next unless kv.is_a?(Hash) && kv["key"]
        h[kv["key"]] = unwrap_attribute_value(kv["value"])
      end
    when Hash
      raw.transform_values { |v| unwrap_attribute_value(v) }
    else
      {}
    end
  end

  private

  # Unwrap a stored attribute value to a scalar for display. Handles the Sentry
  # {"value"=>x} wrapper and the OTLP AnyValue ({stringValue|intValue|...});
  # arrayValue/kvlistValue keep their structure rather than guessing.
  def unwrap_attribute_value(value)
    return value unless value.is_a?(Hash)
    return value["value"] if value.key?("value")
    %w[stringValue intValue boolValue doubleValue].each do |k|
      return value[k] if value.key?(k)
    end
    value["arrayValue"] || value["kvlistValue"] || value
  end
end

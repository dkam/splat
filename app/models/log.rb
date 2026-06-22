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

  # Decoded-payload readers (lazy; only decompress the blob on access).
  def payload_attributes = payload&.dig("attributes") || {}
end

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
  scope :by_release, ->(release) { where(release: release) }
  scope :by_source, ->(source) { where(source: source) }
  scope :by_service, ->(service) { where(service: service) }
  # Indexed only via project_id+service above; server_name has no index of its
  # own, so this is a filter applied over the timestamp window rather than a
  # lookup. Cheap in that context, not something to lean on unwindowed.
  scope :by_server_name, ->(name) { where(server_name: name) }
  # duration_ms is populated from a source-provided attribute (e.g. Postgres
  # slow-query duration via the OTLP collector). Backs a future "min duration"
  # filter; the partial index covers the non-null slice.
  scope :slower_than, ->(ms) { where("duration_ms >= ?", ms) }
  # Free-text search over message body + flattened attributes via the logs_fts
  # FTS5 index (see config/initializers/logs_fts.rb). Falls back to all when the
  # query has no usable terms.
  #
  # Pass `within:` (the same time range the caller is already filtering on) for
  # any windowed search. Without it the timestamp window contributes *nothing*
  # to the plan: SQLite materialises every rowid matching the term across the
  # whole table, does one random row fetch per match, then sorts the lot in a
  # temp B-tree before LIMIT can apply — so a 30-minute window costs the same as
  # a 30-day one, and a common term over a 14M-row table never returns. With it,
  # FTS5 accepts the rowid constraint and only walks the doclist for that id
  # range (the plan's index string gains a `<`/`>` marker).
  scope :search_text, ->(text, within: nil) {
    q = fts_query(text)
    next all unless q

    lo, hi = within ? id_bounds_for(within) : nil
    if within && lo.nil?
      # No rows in the window at all — nothing to match, and MATCH with a null
      # bound would be a syntax error.
      none
    elsif lo
      where("logs.id IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ? AND rowid BETWEEN ? AND ?)", q, lo, hi)
    else
      where("logs.id IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)", q)
    end
  }

  # Lowest and highest id among rows whose timestamp falls in `range`.
  #
  # Exact by construction: every row in the window is one of the rows this
  # aggregates over, so its id is within the bounds returned. That matters
  # because ids are assigned in ingest order, not timestamp order — a delayed
  # OTLP batch lands with an id far above rows that are newer by timestamp.
  # Deriving the bounds from the window's own rows (rather than assuming the
  # two orders agree) means a late arrival widens the range instead of being
  # dropped from the results.
  #
  # index_logs_on_timestamp covers this outright: SQLite reads MIN(id)/MAX(id)
  # straight out of the index without touching the table.
  #
  # Explicitly `Log.unscoped`, not a bare `where`: called from the search_text
  # scope body, a bare class-method call is delegated through the current
  # relation's scoping, which would drag `recent`'s ORDER BY (and any other
  # accumulated clause) into what should be one clean covering index read.
  def self.id_bounds_for(range)
    Log.unscoped.where(timestamp: range).pick(Arel.sql("MIN(logs.id)"), Arel.sql("MAX(logs.id)"))
  end

  # Turn free user input into a safe FTS5 MATCH expression. Punctuation/operators
  # in the input can't break the query or inject FTS syntax (everything is
  # reduced to quoted token phrases). Supports a `key:value` shorthand for
  # attribute-scoped matches. Returns nil when there's nothing to search.
  def self.fts_query(text)
    return nil if text.blank?

    # Collapse pasted UUIDs the same way the index does, so a hyphenated UUID
    # matches its single stored token instead of fragmenting into five terms.
    clauses = Logs::Uuid.collapse(text.to_s).split(/\s+/).filter_map do |term|
      if term.include?(":")
        # key:value — match the key and its value as an adjacent phrase.
        # attrs_text stores "… key value …" with the value's tokens right after
        # the key, so a phrase of [key, *value_tokens] is scoped to that key
        # (e.g. status:422 won't match a 422 belonging to some other field).
        key, val = term.split(":", 2)
        toks = "#{key} #{val}".scan(/[\p{Alnum}_]+/)
        next if toks.empty?
        %("#{toks.join(" ")}")
      else
        # Bare text — each token ANDed (a token may split on punctuation).
        toks = term.scan(/[\p{Alnum}_]+/)
        next if toks.empty?
        toks.map { |t| %("#{t}") }.join(" ")
      end
    end

    clauses.empty? ? nil : clauses.join(" ")
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

  def unwrap_attribute_value(value) = Logs::AttributeValue.unwrap(value)
end

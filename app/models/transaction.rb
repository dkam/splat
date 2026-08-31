# frozen_string_literal: true

class Transaction < TransactionsSpansRecord
  include TransactionAnalytics

  # Spans beyond this cap are dropped at ingest.
  SPAN_CAP = 1000

  # contexts.trace.data is where every SDK but Rails puts the attributes of
  # the transaction's own span: sentry-go's Span.SetData lands there and
  # nowhere else, and Python, Node and Rust do the same — it is the location
  # Sentry standardised on when span attributes were aligned with OpenTelemetry.
  # Rails is the outlier only because its integration predates that and rides
  # ActiveSupport::Notifications instead.
  #
  # A few of those keys are the same facts Splat already has columns for, so
  # they promote rather than being stored twice. Both spellings are listed
  # because the OTel-aligned names (http.request.method) replaced the older
  # flat ones (http.method) and SDKs in the wild still send either.
  TRACE_DATA_HTTP_METHOD = %w[http.request.method http.method].freeze
  TRACE_DATA_HTTP_STATUS = %w[http.response.status_code http.status_code].freeze
  TRACE_DATA_HTTP_URL = %w[url.full http.url].freeze
  TRACE_DATA_PROMOTED = (TRACE_DATA_HTTP_METHOD + TRACE_DATA_HTTP_STATUS + TRACE_DATA_HTTP_URL).freeze

  # What's left rides in the measurements JSON, which is a plain uncompressed
  # column — unlike span trees, logs and events, which go through
  # Compression::Codec. Nothing in the protocol caps contexts.trace.data, and
  # an SDK is free to attach a serialized request body to it, so it is bounded
  # here the way SQL text (MAX_SQL_LENGTH) and spans (SPAN_CAP) already are.
  # Real payloads carry a handful of short scalars; these ceilings only bite on
  # something that was going to be unreadable in a detail panel anyway.
  SPAN_DATA_MAX_KEYS = 50
  SPAN_DATA_MAX_VALUE_LENGTH = 1000

  # project + releases live on the primary DB.
  belongs_to :project

  validates :transaction_id, presence: true, uniqueness: {scope: :project_id}
  validates :timestamp, presence: true
  validates :transaction_name, presence: true
  validates :duration, presence: true, numericality: {greater_than_or_equal_to: 0}

  scope :recent, -> { order(timestamp: :desc) }
  # NOTE: no `scope :slow` — TransactionAnalytics.slow(time_range:, …) is the
  # public API (used by MCP search_slow_transactions). A no-arg scope here would
  # silently override it (scope is defined after the include) and break callers.
  scope :by_name, ->(name) { where(transaction_name: name) }
  scope :by_environment, ->(env) { where(environment: env) }
  scope :by_server, ->(server) { where(server_name: server) }
  scope :by_http_status, ->(status) { where(http_status: status) }
  scope :by_http_method, ->(method) { where(http_method: method) }
  scope :by_release, ->(release) { where(release: release) }

  scope :last_hour, -> { where("timestamp > ?", 1.hour.ago) }
  scope :last_24_hours, -> { where("timestamp > ?", 24.hours.ago) }
  scope :last_7_days, -> { where("timestamp > ?", 7.days.ago) }

  # Live-hour aggregates: the duration histogram (percentiles) and the scalar
  # stats (count/avg/max/min/queries/N+1/errors). Runs inside the insert's
  # transaction so the row and its aggregate deltas commit atomically, and only
  # on a genuine insert (find_or_initialize skips the save on redelivery), so it
  # can't double-count. The hourly rollup later overwrites each hour with an
  # authoritative recount. Lives on the model — not the ingest consumer — so
  # every create path (console, backfills, tests) keeps the aggregates correct.
  after_create :record_hourly_aggregates

  after_create_commit :broadcast_transaction_update

  def self.create_from_sentry_payload!(transaction_id, payload, project)
    start_timestamp = parse_timestamp(payload["start_timestamp"])
    timestamp = parse_timestamp(payload["timestamp"])
    duration = ((timestamp - start_timestamp) * 1000).round if start_timestamp && timestamp

    request_data = payload["request"] || {}
    response_data = payload.dig("contexts", "response") || {}
    trace_data = payload.dig("contexts", "trace", "data") || {}

    # The dedicated contexts win where the client sends them — they are where
    # the protocol puts these facts, and a Rails client fills them in. The
    # trace-data fallback is what lets a Go or Python client have an HTTP
    # method and status at all without writing a middleware to copy them
    # across by hand, one field at a time, per client.
    http_method = request_data["method"] || first_trace_value(trace_data, TRACE_DATA_HTTP_METHOD)
    http_status = response_data["status_code"] || first_trace_value(trace_data, TRACE_DATA_HTTP_STATUS)
    http_url = request_data["url"] || first_trace_value(trace_data, TRACE_DATA_HTTP_URL)

    measurements = payload["measurements"] || {}
    db_time = measurements.dig("db", "value")
    view_time = measurements.dig("view", "value")

    if measurements.empty? && payload["spans"].present?
      span_timing = SpanAnalyzer.extract_timing_data(payload["spans"])
      db_time ||= span_timing[:db_time]
      view_time ||= span_timing[:view_time]
    end

    breadcrumbs_values = payload.dig("breadcrumbs", "values") || []
    query_analysis = SpanAnalyzer.analyze_sql_queries(breadcrumbs_values, spans: payload["spans"] || [])

    # The JSON never duplicates a column: db/view are promoted to db_time/
    # view_time above, so they're excluded here (other client-sent
    # measurements pass through), and of the analyzer's output only
    # query_patterns is stored — query_count/has_n_plus_one are columns, and
    # the reader methods below re-derive unique_patterns and
    # potential_n_plus_one from the per-pattern counts on demand.
    enhanced_measurements = measurements.except("db", "view")
    if query_analysis[:total_queries] > 0
      enhanced_measurements["query_analysis"] = {"query_patterns" => query_analysis[:query_patterns]}
    end

    # Span attributes ride in the measurements JSON under their own key rather
    # than a new column (no migration, and this table is retention-capped) and
    # rather than being merged in flat: measurements are numbers with units and
    # #measurement digs for "value", so smearing arbitrary attributes across
    # the same namespace would make both unreadable. Keys already promoted to
    # columns above are dropped — the JSON never duplicates a column.
    span_data = bounded_span_data(trace_data)
    enhanced_measurements["span_data"] = span_data if span_data.any?

    query_count = query_analysis[:total_queries].to_i
    has_n_plus_one = query_analysis[:potential_n_plus_one].to_a.any?

    attributes = {
      project: project,
      transaction_id: transaction_id,
      timestamp: timestamp || Time.current,
      transaction_name: payload["transaction"],
      op: payload.dig("contexts", "trace", "op"),
      # Promoted from spans so log↔transaction correlation is a transaction-table
      # lookup (see LogsController#related_transaction), not a span query.
      trace_id: payload.dig("contexts", "trace", "trace_id"),
      duration: duration || 0,
      db_time: db_time,
      view_time: view_time,
      environment: payload["environment"],
      release: payload["release"],
      server_name: payload["server_name"],
      http_method: http_method,
      http_status: http_status,
      http_url: http_url,
      tags: payload["tags"] || {},
      measurements: enhanced_measurements,
      query_count: query_count,
      has_n_plus_one: has_n_plus_one,
      n_plus_one_time: query_analysis[:n_plus_one_time_ms],
      spans_truncated: payload["spans"].is_a?(Array) && payload["spans"].size > SPAN_CAP
    }

    transaction = find_or_initialize_by(project_id: project.id, transaction_id: transaction_id)
    if transaction.new_record?
      transaction.assign_attributes(attributes)
      transaction.save!
    else
      Rails.logger.info "Skipping duplicate transaction: #{transaction_id}"
    end
    transaction
  rescue => e
    Rails.logger.error "Failed to create transaction from payload: #{e.message}"
    raise
  end

  # The histogram-merge percentile reader lives in TransactionAnalytics as the
  # single parameterized #merged_percentiles (used for project-wide, substring,
  # and exact-endpoint percentiles). Kept there so writer (rollup) and reader
  # share one bucket formula via Analytics::Histogram.bucket_index_sql.

  # The span attributes worth storing: everything not already promoted to a
  # column, capped in both directions. Structure is preserved for anything
  # under the ceiling — only an oversized value collapses to truncated JSON,
  # because a hash that has to be cut is no longer a hash worth parsing.
  def self.bounded_span_data(trace_data)
    data = trace_data.except(*TRACE_DATA_PROMOTED)
    data = data.first(SPAN_DATA_MAX_KEYS).to_h if data.size > SPAN_DATA_MAX_KEYS
    data.transform_values { |value| bounded_span_value(value) }
  end

  def self.bounded_span_value(value)
    return value if value.nil? || value.is_a?(Numeric) || [true, false].include?(value)

    text = value.is_a?(String) ? value : value.to_json
    return value if text.length <= SPAN_DATA_MAX_VALUE_LENGTH
    "#{text[0, SPAN_DATA_MAX_VALUE_LENGTH]}…"
  end

  # First present value among the accepted spellings of one trace-data key.
  def self.first_trace_value(trace_data, keys)
    keys.filter_map { |key| trace_data[key] }.first
  end

  def self.parse_timestamp(timestamp)
    case timestamp
    when String then Time.parse(timestamp)
    when Numeric then Time.at(timestamp)
    when Time then timestamp
    end
  rescue => e
    Rails.logger.error "Failed to parse timestamp #{timestamp}: #{e.message}"
    nil
  end

  # ---- Accessors over the plain JSON columns. self[] bypasses any
  # overridden reader and tolerates NULL → {}. ----
  def tags = self[:tags] || {}
  def measurements = self[:measurements] || {}
  def tag(key) = tags[key]
  def measurement(key) = measurements.dig(key, "value")
  def query_analysis = measurements["query_analysis"] || {}

  # Attributes the client attached to the transaction's own span, minus the
  # ones promoted to columns. Empty for a Rails client, which has no
  # equivalent — see TRACE_DATA_PROMOTED.
  def span_data = measurements["span_data"] || {}

  def slow? = duration.present? && duration > 1000
  def http_success? = http_status.present? && http_status.to_s.start_with?("2")
  def http_error? = http_status.present? && http_status.to_s.start_with?("4", "5")

  def db_overhead_percentage
    return 0 unless duration.present? && db_time.present? && duration > 0
    ((db_time.to_f / duration) * 100).round(2)
  end

  def view_overhead_percentage
    return 0 unless duration.present? && view_time.present? && duration > 0
    ((view_time.to_f / duration) * 100).round(2)
  end

  def other_time
    return 0 unless duration.present?
    other = duration
    other -= db_time if db_time.present?
    other -= view_time if view_time.present?
    [other, 0].max
  end

  # The errors thrown during this transaction — the reverse of
  # Event#related_transaction. Events live in the issues_events DB, so this is a
  # project-scoped query rather than an association; it rides the events
  # (project_id, trace_id) index. trace_id is not globally unique, hence the
  # project scope. Empty is the norm — most transactions raise nothing.
  def related_events
    return Event.none if trace_id.blank?
    Event.where(project_id: project_id, trace_id: trace_id).order(timestamp: :desc)
  end

  # Column wins over JSON; the JSON fallback handles legacy rows that
  # predate the promoted column.
  def query_count
    self[:query_count] || query_analysis["total_queries"] || 0
  end

  def has_n_plus_one_queries?
    return has_n_plus_one unless has_n_plus_one.nil?
    potential_n_plus_one_queries.any?
  end

  def query_patterns = query_analysis["query_patterns"] || {}

  # Derived from query_patterns for rows written since the measurements slim;
  # legacy rows stored these keys explicitly and keep their as-written values.
  def unique_query_patterns
    query_analysis["unique_patterns"] || query_patterns.size
  end

  def potential_n_plus_one_queries
    query_analysis["potential_n_plus_one"] ||
      query_patterns.select { |_, data| data["count"].to_i > SpanAnalyzer::N_PLUS_ONE_THRESHOLD }.keys
  end

  def controller_action
    return nil unless transaction_name.present?
    transaction_name if transaction_name.include?("#")
  end

  def controller = controller_action&.split("#")&.first
  def action = controller_action&.split("#")&.last

  private

  def record_hourly_aggregates
    Analytics::Histogram.bump_many!([[project_id, transaction_name, environment, timestamp, duration]])
    Analytics::HourlyStats.bump_many!([self])
  end

  def broadcast_transaction_update
    cache_key = "transaction_broadcast_#{project_id}"
    last_broadcast = Rails.cache.read(cache_key)
    throttle_interval = broadcast_interval
    last_broadcast = Time.parse(last_broadcast) if last_broadcast.is_a?(String)

    if last_broadcast.nil? || last_broadcast < throttle_interval.seconds.ago
      Rails.cache.write(cache_key, Time.current, expires_in: 1.hour)
      project.broadcast_refresh_to(project, "transactions")
    end
  end

  def broadcast_interval
    ENV.fetch("TRANSACTION_BROADCAST_INTERVAL", 3).to_i
  end
end

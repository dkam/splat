# frozen_string_literal: true

class Transaction < TransactionsSpansRecord
  include TransactionAnalytics

  # Spans beyond this cap are dropped at ingest.
  SPAN_CAP = 1000

  # project + releases live on the primary DB.
  belongs_to :project

  validates :transaction_id, presence: true, uniqueness: { scope: :project_id }
  validates :timestamp, presence: true
  validates :transaction_name, presence: true
  validates :duration, presence: true, numericality: { greater_than_or_equal_to: 0 }

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

  scope :last_hour,    -> { where("timestamp > ?", 1.hour.ago) }
  scope :last_24_hours, -> { where("timestamp > ?", 24.hours.ago) }
  scope :last_7_days,  -> { where("timestamp > ?", 7.days.ago) }

  after_create_commit :broadcast_transaction_update

  def self.create_from_sentry_payload!(transaction_id, payload, project)
    start_timestamp = parse_timestamp(payload["start_timestamp"])
    timestamp       = parse_timestamp(payload["timestamp"])
    duration        = ((timestamp - start_timestamp) * 1000).round if start_timestamp && timestamp

    request_data  = payload["request"] || {}
    response_data = payload.dig("contexts", "response") || {}

    measurements = payload["measurements"] || {}
    db_time   = measurements.dig("db", "value")
    view_time = measurements.dig("view", "value")

    if measurements.empty? && payload["spans"].present?
      span_timing = SpanAnalyzer.extract_timing_data(payload["spans"])
      db_time   ||= span_timing[:db_time]
      view_time ||= span_timing[:view_time]
    end

    breadcrumbs_values = payload.dig("breadcrumbs", "values") || []
    query_analysis     = SpanAnalyzer.analyze_sql_queries(breadcrumbs_values)

    enhanced_measurements = measurements.dup
    enhanced_measurements["span_extracted_db_time"]   = db_time if db_time.present?
    enhanced_measurements["span_extracted_view_time"] = view_time if view_time.present?
    enhanced_measurements["query_analysis"]           = query_analysis if query_analysis[:total_queries] > 0

    query_count    = query_analysis[:total_queries].to_i
    has_n_plus_one = query_analysis[:potential_n_plus_one].to_a.any?

    attributes = {
      project: project,
      transaction_id: transaction_id,
      timestamp: timestamp || Time.current,
      transaction_name: payload["transaction"],
      op: payload.dig("contexts", "trace", "op"),
      duration: duration || 0,
      db_time: db_time,
      view_time: view_time,
      environment: payload["environment"],
      release: payload["release"],
      server_name: payload["server_name"],
      http_method: request_data["method"],
      http_status: response_data["status_code"],
      http_url: request_data["url"],
      tags: payload["tags"] || {},
      measurements: enhanced_measurements,
      query_count: query_count,
      has_n_plus_one: has_n_plus_one,
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

  # Histogram-merge percentile reader. Returns ms for the requested
  # quantile (0..1). Returns nil if no histogram rows fall in the window.
  # Pre-computed hours come from transaction_histograms; the in-progress
  # hour is unioned in from raw rows so live data is included.
  # When environment is given, both arms filter to that env (transaction_histograms
  # stores env as '' when the source row was NULL, so an explicit env filter
  # never matches the no-env bucket).
  def self.histogram_percentile(project_id:, transaction_name:, quantile:, since:, until_time: Time.current, environment: nil)
    hour_start = Analytics::Histogram.hour_bucket(since)
    until_hour = Analytics::Histogram.hour_bucket(until_time)
    # project_id is bound only when present: `project_id = NULL` matches no
    # rows, so a nil (= "all projects") caller would otherwise get 0ms back.
    proj_filter = project_id.present? ? "AND project_id = ?" : ""
    env_filter  = environment.present? ? "AND environment = ?" : ""
    sql = <<~SQL
      WITH merged AS (
        SELECT bucket_index, SUM(count) AS c
          FROM transaction_histograms
         WHERE transaction_name = ?
           AND hour_bucket >= ? AND hour_bucket < ?
           #{proj_filter}
           #{env_filter}
         GROUP BY bucket_index
        UNION ALL
        SELECT CAST(FLOOR(LN(MAX(duration, 1)) / LN(?)) AS INTEGER) AS bucket_index,
               COUNT(*) AS c
          FROM transactions
         WHERE transaction_name = ?
           AND timestamp >= ? AND timestamp < ?
           #{proj_filter}
           #{env_filter}
         GROUP BY 1
      ), reduced AS (
        SELECT bucket_index, SUM(c) AS c FROM merged GROUP BY bucket_index
      ), running AS (
        SELECT bucket_index, c,
               SUM(c) OVER (ORDER BY bucket_index) AS cum,
               SUM(c) OVER () AS total
          FROM reduced
      )
      SELECT bucket_index FROM running
       WHERE cum >= ? * total
       ORDER BY bucket_index
       LIMIT 1
    SQL
    # Raw-branch lower bound is the later of `since` and `until_hour`: if both
    # `since` and `until_time` land in the same hour, `until_hour` < `since`
    # and the raw window would otherwise widen to the start of the hour.
    raw_lower = [since, until_hour].max
    binds = [transaction_name, hour_start, until_hour]
    binds << project_id  if project_id.present?
    binds << environment if environment.present?
    binds << Analytics::Histogram::GAMMA
    binds.push(transaction_name, raw_lower, until_time)
    binds << project_id  if project_id.present?
    binds << environment if environment.present?
    binds << quantile
    bucket = connection.select_value(sanitize_sql_array([sql, *binds]))
    return nil if bucket.nil?
    Analytics::Histogram.index_to_ms(bucket.to_i)
  end

  def self.parse_timestamp(timestamp)
    case timestamp
    when String  then Time.parse(timestamp)
    when Numeric then Time.at(timestamp)
    when Time    then timestamp
    end
  rescue => e
    Rails.logger.error "Failed to parse timestamp #{timestamp}: #{e.message}"
    nil
  end

  # ---- Accessors over the plain JSON columns. self[] bypasses any
  # overridden reader and tolerates NULL → {}. ----
  def tags         = self[:tags] || {}
  def measurements = self[:measurements] || {}
  def tag(key)         = tags[key]
  def measurement(key) = measurements.dig(key, "value")
  def query_analysis   = measurements["query_analysis"] || {}

  def slow?         = duration.present? && duration > 1000
  def http_success? = http_status.present? && http_status.to_s.start_with?("2")
  def http_error?   = http_status.present? && http_status.to_s.start_with?("4", "5")

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
    other -= db_time   if db_time.present?
    other -= view_time if view_time.present?
    [ other, 0 ].max
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

  def unique_query_patterns         = query_analysis["unique_patterns"] || 0
  def potential_n_plus_one_queries  = query_analysis["potential_n_plus_one"] || []
  def query_patterns                = query_analysis["query_patterns"] || {}

  def controller_action
    return nil unless transaction_name.present?
    transaction_name if transaction_name.include?("#")
  end

  def controller = controller_action&.split("#")&.first
  def action     = controller_action&.split("#")&.last

  private

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

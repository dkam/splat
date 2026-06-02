# frozen_string_literal: true

class Event < IssuesEventsRecord
  include Compression::CompressedJson
  compressed_json :payload, db: :issues_events, table: "events", platform: :platform

  # project lives on the primary DB. The belongs_to still works for
  # `event.project` (issues a separate SELECT against primary), but Rails
  # won't generate a cross-DB JOIN, so avoid `.includes(:project)` here.
  belongs_to :project
  belongs_to :issue, optional: true, counter_cache: :count

  # Scope to project_id so the validator's lookup uses the
  # index_events_on_project_id_and_event_id unique index instead of full-scanning.
  validates :event_id, presence: true, uniqueness: { scope: :project_id }
  validates :timestamp, presence: true

  # Per-event broadcasts are throttled to avoid swamping during error bursts.
  # The Issue#after_update_commit callback covers issue-status changes; this
  # only refreshes event-list views at most once per BROADCAST_THROTTLE.
  BROADCAST_THROTTLE = 5.seconds

  after_create_commit :throttled_broadcast_refresh

  scope :recent, -> { order(timestamp: :desc) }
  scope :by_issue, ->(issue_id) { where(issue_id: issue_id) }
  scope :by_environment, ->(env) { where(environment: env) }
  scope :by_platform, ->(platform) { where(platform: platform) }
  scope :by_exception_type, ->(type) { where(exception_type: type) }

  # Extract promoted columns from payload before saving.
  before_validation :extract_fields_from_payload

  def self.create_from_sentry_payload!(event_id, payload, project)
    timestamp = parse_timestamp(payload["timestamp"])

    issue = Issue.group_event(payload, project, timestamp: timestamp)

    event = create!(
      project: project,
      event_id: event_id,
      issue: issue,
      timestamp: timestamp,
      payload: payload,
      platform: payload["platform"],
      sdk_name: payload.dig("sdk", "name"),
      sdk_version: payload.dig("sdk", "version"),
      environment: payload["environment"],
      release: payload["release"],
      server_name: payload["server_name"],
      transaction_name: payload["transaction"]
    )

    # counter_cache bumps issue.count, but last_seen has no auto-update.
    # Conditional WHERE keeps out-of-order events from clobbering a newer timestamp.
    Issue.where(id: issue.id)
         .where("last_seen < ?", event.timestamp)
         .update_all(last_seen: event.timestamp, updated_at: Time.current)

    event
  end

  def self.parse_timestamp(timestamp)
    case timestamp
    when String
      Time.parse(timestamp)
    when Numeric
      Time.at(timestamp)
    when Time
      timestamp
    else
      Time.current
    end
  rescue => e
    Rails.logger.error "Failed to parse timestamp #{timestamp}: #{e.message}"
    Time.current
  end

  def self.count_in_range(time_range:, project_id: nil)
    scope = all
    scope = scope.where(timestamp: time_range)  if time_range
    scope = scope.where(project_id: project_id) if project_id
    scope.count
  end

  # Hourly bucket counts for issue/event sparklines.
  #   { issue_id => Array(bucket_count, ...) }, oldest bucket first.
  def self.event_counts_by_bucket(issue_ids:, time_range:, buckets:, project_id: nil)
    return {} if issue_ids.empty?
    window         = time_range.end - time_range.begin
    bucket_seconds = (window / buckets).to_i.clamp(1, nil)
    range_start    = time_range.begin

    scope = where(issue_id: issue_ids).where(timestamp: time_range)
    scope = scope.where(project_id: project_id) if project_id
    rows = scope
           .group(:issue_id)
           .group(Arel.sql("CAST((strftime('%s', timestamp) - #{range_start.to_i}) / #{bucket_seconds} AS INTEGER)"))
           .count

    result = issue_ids.each_with_object({}) { |id, h| h[id] = Array.new(buckets, 0) }
    rows.each do |(issue_id, bucket_idx), count|
      idx = bucket_idx.to_i
      next if idx < 0 || idx >= buckets
      result[issue_id] ||= Array.new(buckets, 0)
      result[issue_id][idx] = count
    end
    result
  end

  # Volume across all events bucketed by time.
  def self.volume_by_bucket(project_id:, time_range:, buckets:)
    window         = time_range.end - time_range.begin
    bucket_seconds = (window / buckets).to_i.clamp(1, nil)
    range_start    = time_range.begin

    rows = where(project_id: project_id)
           .where(timestamp: time_range)
           .group(Arel.sql("CAST((strftime('%s', timestamp) - #{range_start.to_i}) / #{bucket_seconds} AS INTEGER)"))
           .count

    Array.new(buckets, 0).tap do |result|
      rows.each do |idx, c|
        i = idx.to_i
        result[i] = c if i >= 0 && i < buckets
      end
    end
  end

  # ---- Convenience readers backed by the decoded payload. ----
  def exception_details
    return {} unless payload.present?
    exception_data = payload.dig("exception", "values", 0) || {}
    {
      type: exception_data["type"],
      value: exception_data["value"],
      mechanism: exception_data["mechanism"],
      stacktrace: exception_data["stacktrace"]
    }
  end

  def stacktrace      = exception_details[:stacktrace]
  def message         = payload&.dig("message") || exception_value
  def level           = payload&.dig("level") || "error"
  def tags            = payload&.dig("tags") || {}
  def user            = payload&.dig("user") || {}
  def request         = payload&.dig("request") || {}
  def contexts        = payload&.dig("contexts") || {}
  def breadcrumbs     = payload&.dig("breadcrumbs", "values") || []
  def fingerprint     = payload&.dig("fingerprint") || []

  private

  def throttled_broadcast_refresh
    if issue&.persisted?
      throttle_broadcast("issue:#{issue_id}") { issue.broadcast_refresh_later }
    end
    throttle_broadcast("project:#{project_id}:events") { project.broadcast_events_refresh }
    throttle_broadcast("project:#{project_id}:issues") { project.broadcast_issues_refresh }
  end

  def throttle_broadcast(key)
    cache_key = "event_broadcast_throttle:#{key}"
    Rails.cache.fetch(cache_key, expires_in: BROADCAST_THROTTLE) do
      yield
      true
    end
  end

  def extract_fields_from_payload
    return unless payload.present?

    exception_data = payload.dig("exception", "values", 0) || {}
    self.exception_type = exception_data["type"]
    self.exception_value = exception_data["value"]

    if payload["fingerprint"].present?
      self[:fingerprint] = payload["fingerprint"].to_s
    end
  end
end

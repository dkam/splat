# frozen_string_literal: true

class Event < ApplicationRecord
  belongs_to :project
  belongs_to :issue, optional: true

  validates :event_id, presence: true, uniqueness: true
  validates :timestamp, presence: true

  # Per-event broadcasts are throttled to avoid swamping Solid Queue / Cable during error bursts.
  # The Issue#after_update_commit callback covers issue-status changes; this only refreshes
  # event-list views at most once per BROADCAST_THROTTLE per stream.
  BROADCAST_THROTTLE = 5.seconds

  after_create_commit :throttled_broadcast_refresh

  scope :recent, -> { order(timestamp: :desc) }
  scope :by_issue, ->(issue_id) { where(issue_id: issue_id) }
  scope :by_environment, ->(env) { where(environment: env) }
  scope :by_platform, ->(platform) { where(platform: platform) }
  scope :by_exception_type, ->(type) { where(exception_type: type) }

  # Extract key fields from payload before saving
  before_validation :extract_fields_from_payload

  def self.create_from_sentry_payload!(event_id, payload, project)
    # Find or create the issue for grouping
    issue = Issue.group_event(payload, project)

    # Create the event
    create!(
      project: project,
      event_id: event_id,
      issue: issue,
      timestamp: parse_timestamp(payload["timestamp"]),
      payload: payload,
      platform: payload["platform"],
      sdk_name: payload.dig("sdk", "name"),
      sdk_version: payload.dig("sdk", "version"),
      environment: payload["environment"],
      release: payload["release"],
      server_name: payload["server_name"],
      transaction_name: payload["transaction"]
    )
  end

  def self.parse_timestamp(timestamp)
    case timestamp
    when String
      Time.parse(timestamp)
    when Numeric
      # Sentry timestamps can be in seconds with decimals
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

  def stacktrace
    exception_details[:stacktrace]
  end

  def exception_type
    exception_details[:type]
  end

  def exception_value
    exception_details[:value]
  end

  def message
    payload&.dig("message") || exception_value
  end

  def level
    payload&.dig("level") || "error"
  end

  def tags
    payload&.dig("tags") || {}
  end

  def user
    payload&.dig("user") || {}
  end

  def request
    payload&.dig("request") || {}
  end

  def contexts
    payload&.dig("contexts") || {}
  end

  def breadcrumbs
    payload&.dig("breadcrumbs", "values") || []
  end

  def fingerprint
    payload&.dig("fingerprint") || []
  end

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
    # fetch only invokes the block on a cache miss; subsequent calls within the
    # TTL return the cached marker and skip the (expensive) broadcast enqueue.
    Rails.cache.fetch(cache_key, expires_in: BROADCAST_THROTTLE) do
      yield
      true
    end
  end

  def extract_fields_from_payload
    return unless payload.present?

    # Extract exception details for direct querying
    exception_data = payload.dig("exception", "values", 0) || {}
    self.exception_type = exception_data["type"]
    self.exception_value = exception_data["value"]

    # Extract fingerprint for grouping (if provided)
    if payload["fingerprint"].present?
      self.fingerprint = payload["fingerprint"]
    end
  end
end

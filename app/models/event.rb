# frozen_string_literal: true

class Event < IssuesEventsRecord
  include Compression::CompressedJson

  compressed_json :payload, db: :issues_events, table: "events", platform: :platform

  # project lives on the primary DB. The belongs_to still works for
  # `event.project` (issues a separate SELECT against primary), but Rails
  # won't generate a cross-DB JOIN, so avoid `.includes(:project)` here.
  belongs_to :project
  belongs_to :issue, optional: true, counter_cache: :count

  # Uniqueness of (project_id, event_id) is enforced solely by the
  # index_events_on_project_id_and_event_id unique index. A model-level
  # uniqueness validator would raise RecordInvalid on redelivery (and run a
  # SELECT on every insert); EventConsumer rescues the DB's RecordNotUnique
  # instead, so a redelivered job is a clean no-op.
  validates :event_id, presence: true
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
      transaction_name: payload["transaction"],
      # Promoted from the payload so error <-> transaction <-> log correlation
      # is an indexed lookup. transaction_name only names an endpoint (and is
      # NULL for background jobs); the trace is the only thing tying an error to
      # the specific request that threw it.
      trace_id: payload.dig("contexts", "trace", "trace_id")
    )

    # counter_cache bumps issue.count, but last_seen has no auto-update.
    # Conditional WHERE keeps out-of-order events from clobbering a newer timestamp.
    Issue.where(id: issue.id)
      .where("last_seen < ?", event.timestamp)
      .update_all(last_seen: event.timestamp, updated_at: Time.current)

    # Best-effort side effects; both throttled, and neither raises into ingest.
    issue.harvest_facets!(environment: event.environment, release: event.release, seen_at: event.timestamp)
    issue.maybe_alert_burst!

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
    scope = scope.where(timestamp: time_range) if time_range
    scope = scope.where(project_id: project_id) if project_id
    scope.count
  end

  # Hourly bucket counts for issue/event sparklines.
  #   { issue_id => Array(bucket_count, ...) }, oldest bucket first.
  def self.event_counts_by_bucket(issue_ids:, time_range:, buckets:, project_id: nil)
    return {} if issue_ids.empty?
    window = time_range.end - time_range.begin
    bucket_seconds = (window / buckets).to_i.clamp(1, nil)
    range_start = time_range.begin

    scope = where(issue_id: issue_ids).where(timestamp: time_range)
    scope = scope.where(project_id: project_id) if project_id
    rows = scope
      .group(:issue_id)
      .group(Arel.sql(Analytics::Histogram.time_bucket_sql(origin_epoch: range_start.to_i, bucket_seconds: bucket_seconds)))
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

  # Events per hour for the last `hours` hours, oldest first — the projects
  # index sparkline.
  #
  # There's no hourly rollup table for events the way there is for transactions
  # (transaction_hourly_stats), and a 24h scan per project per page load is not
  # cheap on an instance taking hundreds of thousands of events a day. So the
  # buckets are cached individually, keyed by the hour they describe:
  #
  #   * settled hours (older than SETTLING_HOURS) never change, so they're
  #     computed once and kept for a day. No invalidation to get wrong — the
  #     key names the hour.
  #   * the settling window and the in-progress hour are recomputed, because
  #     an event's `timestamp` is when it happened, not when it landed: Splat's
  #     own ingest queue can run behind, and a backfilled hour has to be able
  #     to fill in after the fact.
  #
  # A warm load therefore scans SETTLING_HOURS + 1 hours of events instead of
  # 24. A cold one costs what the old full scan did, once.
  SETTLING_HOURS = 2
  HOUR_VOLUME_TTL = 25.hours

  def self.hourly_volume(project_id:, hours: 24, ending_at: Time.current)
    current_hour = Analytics::Histogram.hour_bucket(ending_at)
    buckets = Array.new(hours) { |i| current_hour - (hours - 1 - i).hours }
    live_from = current_hour - SETTLING_HOURS.hours

    settled, live = buckets.partition { |hour| hour < live_from }

    keys = settled.to_h { |hour| [hour, hour_volume_cache_key(project_id, hour)] }
    cached = keys.any? ? Rails.cache.read_multi(*keys.values) : {}

    misses = settled.reject { |hour| cached.key?(keys[hour]) }
    if misses.any?
      # One grouped query spanning the gap rather than a query per hour. On a
      # warm cache there are no misses at all; on a cold one the gap is the
      # whole window, which is what the uncached version cost anyway.
      counted = count_by_hour(project_id: project_id, from: misses.first, to: misses.last + 1.hour)
      filled = misses.to_h { |hour| [keys[hour], counted[hour] || 0] }
      Rails.cache.write_multi(filled, expires_in: HOUR_VOLUME_TTL)
      cached.merge!(filled)
    end

    fresh = count_by_hour(project_id: project_id, from: live.first, to: current_hour + 1.hour)

    buckets.map { |hour| (hour < live_from) ? cached[keys[hour]].to_i : fresh[hour].to_i }
  end

  # {Time (hour, UTC) => count} for [from, to). Hours with no events are absent.
  def self.count_by_hour(project_id:, from:, to:)
    where(project_id: project_id, timestamp: from...to)
      .group(Arel.sql(Analytics::Histogram.time_bucket_sql(origin_epoch: from.to_i, bucket_seconds: 3600)))
      .count
      .transform_keys { |index| from + index.to_i.hours }
  end

  def self.hour_volume_cache_key(project_id, hour)
    "event_hourly_volume/v1/#{project_id}/#{hour.to_i}"
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

  def stacktrace = exception_details[:stacktrace]
  # Read the promoted column (populated at ingest) so list views don't
  # decompress the payload blob per row; fall back to exception_value.
  def message = self[:message].presence || exception_value
  def level = payload&.dig("level") || "error"
  def tags = payload&.dig("tags") || {}
  def user = payload&.dig("user") || {}
  def request = payload&.dig("request") || {}
  def contexts = payload&.dig("contexts") || {}
  def breadcrumbs = payload&.dig("breadcrumbs", "values") || []

  # The transaction this error was thrown inside, or nil. Mirrors
  # LogsController#related_transaction — trace_id is not globally unique, so the
  # lookup is scoped to the project and rides the (project_id, trace_id) index.
  #
  # nil is expected and not a problem: events written before trace_id was
  # promoted have none (until the backfill rake task runs), and a transaction
  # only exists if that request was sampled for tracing.
  def related_transaction
    return nil if trace_id.blank?
    Transaction.find_by(project_id: project_id, trace_id: trace_id)
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

    # Promote the display message so Event#message reads a column, not the blob.
    # Sentry's "message" is a string or a {message, params, formatted} object.
    raw_message = payload["message"]
    self.message = raw_message.is_a?(Hash) ? raw_message["formatted"] : raw_message

    if payload["fingerprint"].present?
      self[:fingerprint] = Array.wrap(payload["fingerprint"]).join("::")
    end
  end
end

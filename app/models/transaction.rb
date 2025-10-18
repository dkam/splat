# frozen_string_literal: true

class Transaction < ApplicationRecord
  belongs_to :project

  validates :transaction_id, presence: true, uniqueness: true
  validates :timestamp, presence: true
  validates :transaction_name, presence: true
  validates :duration, presence: true, numericality: { greater_than_or_equal_to: 0 }

  scope :recent, -> { order(timestamp: :desc) }
  scope :slow, -> { where("duration > ?", 1000) } # Slower than 1 second
  scope :by_name, ->(name) { where(transaction_name: name) }
  scope :by_environment, ->(env) { where(environment: env) }
  scope :by_server, ->(server) { where(server_name: server) }
  scope :by_http_status, ->(status) { where(http_status: status) }
  scope :by_http_method, ->(method) { where(http_method: method) }

  # Time-based scopes
  scope :last_hour, -> { where("timestamp > ?", 1.hour.ago) }
  scope :last_24_hours, -> { where("timestamp > ?", 24.hours.ago) }
  scope :last_7_days, -> { where("timestamp > ?", 7.days.ago) }

  def self.create_from_sentry_payload!(transaction_id, payload, project)
    # Extract timing information
    start_timestamp = parse_timestamp(payload["start_timestamp"])
    timestamp = parse_timestamp(payload["timestamp"])
    duration = ((timestamp - start_timestamp) * 1000).round if start_timestamp && timestamp

    # Extract HTTP context
    request_data = payload["request"] || {}
    response_data = payload.dig("contexts", "response") || {}

    # Extract measurements
    measurements = payload["measurements"] || {}
    db_time = measurements.dig("db", "value")
    view_time = measurements.dig("view", "value")

    create!(
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
      tags: payload["tags"],
      measurements: measurements
    )
  rescue => e
    Rails.logger.error "Failed to create transaction from payload: #{e.message}"
    raise
  end

  def self.parse_timestamp(timestamp)
    case timestamp
    when String
      Time.parse(timestamp)
    when Numeric
      Time.at(timestamp)
    when Time
      timestamp
    end
  rescue => e
    Rails.logger.error "Failed to parse timestamp #{timestamp}: #{e.message}"
    nil
  end

  def self.stats_by_endpoint(time_range = 24.hours.ago..Time.current)
    where(timestamp: time_range)
      .group(:transaction_name)
      .select(
        :transaction_name,
        "AVG(duration) as avg_duration",
        "MIN(duration) as min_duration",
        "MAX(duration) as max_duration",
        "COUNT(*) as count",
        "AVG(db_time) as avg_db_time",
        "AVG(view_time) as avg_view_time"
      )
      .order("avg_duration DESC")
  end

  def self.percentiles(time_range = 24.hours.ago..Time.current)
    durations = where(timestamp: time_range).pluck(:duration).sort
    return {} if durations.empty?

    {
      avg: durations.sum / durations.size,
      p50: durations[durations.size * 0.5],
      p95: durations[durations.size * 0.95],
      p99: durations[durations.size * 0.99],
      min: durations.first,
      max: durations.last
    }
  end

  def slow?
    duration.present? && duration > 1000
  end

  def http_success?
    http_status.present? && http_status.to_s.start_with?("2")
  end

  def http_error?
    http_status.present? && http_status.to_s.start_with?("4", "5")
  end

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
    [ other, 0 ].max
  end

  def tag(key)
    tags&.dig(key)
  end

  def measurement(key)
    measurements&.dig(key, "value")
  end

  def controller_action
    # Extract controller#action from transaction name if it follows Rails convention
    return nil unless transaction_name.present?

    if transaction_name.include?("#")
      transaction_name
    end
  end

  def controller
    controller_action&.split("#")&.first
  end

  def action
    controller_action&.split("#")&.last
  end
end

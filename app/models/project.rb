# frozen_string_literal: true

class Project < ApplicationRecord
  has_many :events, dependent: :destroy
  has_many :issues, dependent: :destroy
  has_many :transactions, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :public_key, presence: true, uniqueness: true

  scope :by_slug, ->(slug) { where(slug: slug) }
  scope :by_public_key, ->(key) { where(public_key: key) }

  before_validation :generate_slug, if: :name?
  before_validation :generate_public_key, if: -> { public_key.blank? }

  def broadcast_issues_refresh
    # Broadcast to the issues stream for this project
    # Turbo::StreamsChannel.broadcast_refresh_to([self, "issues"])
    broadcast_refresh_to(self, "issues")
  end

  def broadcast_events_refresh
    # Broadcast to the issues stream for this project
    # Turbo::StreamsChannel.broadcast_refresh_to([self, "issues"])
    broadcast_refresh_to(self, "events")
  end

  def self.find_by_dsn(dsn)
    # Parse DSN: https://public_key@host/project_id
    return nil unless dsn.present?

    # Extract public_key from DSN
    match = dsn.match(/https?:\/\/([^@]+)@/)
    return nil unless match

    public_key = match[1]
    find_by(public_key: public_key)
  end

  def self.find_by_project_id(project_id)
    # Try slug first (nicer URLs), then fall back to ID
    find_by(slug: project_id.to_s) || find_by(id: project_id.to_i)
  end

  def dsn
    host = Current.splat_host || "localhost:3000"
    protocol = host.include?("localhost") ? "http" : "https"
    "#{protocol}://#{public_key}@#{host}/#{slug}"
  end

  def internal_dsn
    return nil unless Current.splat_internal_host.present?

    host = Current.splat_internal_host
    protocol = "http"  # Internal Tailscale connections use HTTP
    "#{protocol}://#{public_key}@#{host}/#{slug}"
  end

  def recent_events(limit: 100)
    events.recent.limit(limit)
  end

  def recent_transactions(limit: 100)
    transactions.recent.limit(limit)
  end

  def open_issues
    issues.open.recent
  end

  def event_count(time_range = nil)
    if time_range
      events.where(timestamp: time_range).count
    else
      events.count
    end
  end

  def transaction_count(time_range = nil)
    if time_range
      transactions.where(timestamp: time_range).count
    else
      transactions.count
    end
  end

  def error_rate(time_range = 24.hours.ago..Time.current)
    total_requests = transaction_count(time_range)
    error_events = event_count(time_range)

    return 0 if total_requests == 0

    (error_events.to_f / total_requests * 100).round(2)
  end

  def avg_response_time(time_range = 24.hours.ago..Time.current)
    transactions.where(timestamp: time_range).average(:duration).to_f.round(2)
  end

  def p95_response_time(time_range = 24.hours.ago..Time.current)
    # Cache expensive percentile calculations for 5 minutes
    Rails.cache.fetch("project_#{id}_p95_#{time_range.begin.to_i}_#{time_range.end.to_i}", expires_in: 5.minutes) do
      calculate_p95_percentile(time_range)
    end
  end

  def slowest_endpoints(limit: 10, time_range: 24.hours.ago..Time.current)
    # Cache endpoint analysis for 10 minutes
    Rails.cache.fetch("project_#{id}_slowest_#{limit}_#{time_range.begin.to_i}", expires_in: 10.minutes) do
      calculate_slowest_endpoints(limit, time_range)
    end
  end

  def response_time_by_hour(time_range: 24.hours.ago..Time.current)
    # Cache hourly stats for 5 minutes
    Rails.cache.fetch("project_#{id}_hourly_#{time_range.begin.to_i}", expires_in: 5.minutes) do
      calculate_response_time_by_hour(time_range)
    end
  end

  private

  def calculate_p95_percentile(time_range)
    transaction_count = transactions.where(timestamp: time_range).count

    if transaction_count > 10_000
      # Use sample for large datasets (faster, good enough)
      sample_size = [5000, transaction_count / 10].min
      sample_query = <<~SQL
        SELECT AVG(duration)
        FROM (
          SELECT duration,
                 PERCENT_RANK() OVER (ORDER BY duration) as pr
          FROM (
            SELECT duration
            FROM transactions
            WHERE timestamp BETWEEN ? AND ?
            ORDER BY RANDOM()
            LIMIT ?
          )
        )
        WHERE pr >= 0.95
        LIMIT 1
      SQL

      result = ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql([sample_query, time_range.begin, time_range.end, sample_size])
      ).first
      result&.values&.first&.to_f&.round(2) || 0
    else
      # Full calculation for smaller datasets
      percentile_query = <<~SQL
        SELECT AVG(duration)
        FROM (
          SELECT duration,
                 PERCENT_RANK() OVER (ORDER BY duration) as pr
          FROM transactions
          WHERE timestamp BETWEEN ? AND ?
        )
        WHERE pr >= 0.95
        LIMIT 1
      SQL

      result = ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql([percentile_query, time_range.begin, time_range.end])
      ).first
      result&.values&.first&.to_f&.round(2) || 0
    end
  end

  def calculate_slowest_endpoints(limit, time_range)
    transactions
      .where(timestamp: time_range)
      .group(:transaction_name)
      .select(
        'transaction_name',
        'COUNT(*) as request_count',
        'AVG(duration) as avg_duration',
        'MAX(duration) as max_duration',
        'MIN(duration) as min_duration'
      )
      .order('AVG(duration) DESC')
      .limit(limit)
  end

  def calculate_response_time_by_hour(time_range)
    transactions
      .where(timestamp: time_range)
      .group(Arel.sql("strftime('%H:00', timestamp)"))
      .select(
        Arel.sql("strftime('%H:00', timestamp) as hour_bucket"),
        'COUNT(*) as request_count',
        'AVG(duration) as avg_duration',
        'MAX(duration) as max_duration'
      )
      .order(Arel.sql("strftime('%H:00', timestamp)"))
  end

  def generate_slug
    self.slug = name&.parameterize&.downcase
  end

  def generate_public_key
    # Generate a random 32-character hex string
    self.public_key = SecureRandom.hex(16)
  end
end

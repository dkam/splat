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
    durations = transactions.where(timestamp: time_range).pluck(:duration)
    return 0 if durations.empty?

    (durations.sum / durations.size).round(2)
  end

  private

  def generate_slug
    self.slug = name&.parameterize&.downcase
  end

  def generate_public_key
    # Generate a random 32-character hex string
    self.public_key = SecureRandom.hex(16)
  end
end

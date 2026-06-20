# frozen_string_literal: true

class Project < ApplicationRecord
  has_many :events, dependent: :destroy
  has_many :issues, dependent: :destroy
  has_many :transactions, dependent: :destroy
  has_many :releases, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :public_key, presence: true, uniqueness: true

  scope :by_slug, ->(slug) { where(slug: slug) }
  scope :by_public_key, ->(key) { where(public_key: key) }

  # Slug is the stable identifier in the DSN URL — generate only when blank
  # (i.e. on create) so renaming the display name later doesn't silently
  # change the slug and break every client already pointing at the old DSN.
  before_validation :generate_slug, if: -> { name? && slug.blank? }
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
    Event.count_in_range(time_range: time_range, project_id: id)
  end

  def transaction_count(time_range = nil)
    Transaction.count_in_range(time_range: time_range, project_id: id)
  end

  def error_rate(time_range = 24.hours.ago..Time.current)
    counts = Transaction.total_and_error_count_in_range(time_range: time_range, project_id: id)
    return 0 if counts[:total].zero?

    (counts[:errors].to_f / counts[:total] * 100).round(2)
  end

  # avg/p50/p95 all come from one percentiles call (now a single CTE pass);
  # memoized per time_range so a page reading several doesn't recompute it.
  def response_percentiles(time_range = 24.hours.ago..Time.current)
    (@response_percentiles ||= {})[time_range] ||=
      Transaction.percentiles(time_range, project_id: id)
  end

  def avg_response_time(time_range = 24.hours.ago..Time.current)
    response_percentiles(time_range)[:avg] || 0
  end

  def p50_response_time(time_range = 24.hours.ago..Time.current)
    response_percentiles(time_range)[:p50] || 0
  end

  def p95_response_time(time_range = 24.hours.ago..Time.current)
    response_percentiles(time_range)[:p95] || 0
  end

  def slowest_endpoints(limit: 10, time_range: 24.hours.ago..Time.current)
    Transaction.stats_by_endpoint(time_range, project_id: id, limit: limit)
  end

  def top_endpoints_by_impact(limit: 5, time_range: 24.hours.ago..Time.current)
    Transaction.stats_by_endpoint_with_impact(time_range, project_id: id, limit: limit)
  end

  def response_time_by_hour(time_range: 24.hours.ago..Time.current)
    Transaction.response_time_by_hour(time_range, project_id: id)
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

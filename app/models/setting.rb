# frozen_string_literal: true

# Global application settings for data retention and performance
class Setting < ApplicationRecord
  # Singleton pattern - there's only one settings row
  def self.instance
    first || create!(default_settings)
  end

  def self.default_settings
    {
      # AR (hot) retention — short, drives the OLTP/show-page surface.
      event_payloads_retention_days: 7,    # Keep full JSON payloads for 7 days
      events_data_retention_days: 30,      # Keep basic event data for 30 days
      transaction_measurements_retention_days: 7,  # Keep detailed measurements for 7 days
      transactions_data_retention_days: 90,  # Keep basic transaction data for 90 days

      # DuckLake (cold/analytics) retention — longer, columnar storage is cheap.
      ducklake_events_retention_days: 365,
      ducklake_transactions_retention_days: 365,
      ducklake_issues_retention_days: 730,
      ducklake_spans_retention_days: 30,

      # Noise control — when an open issue's hourly event rate crosses this
      # threshold we send an email + ntfy spike alert (deduped ~1h per issue).
      # If `auto_ignore_enabled` is true we also flip the issue to ignored.
      # The same threshold drives the 🔥 burst badge on the issues list.
      auto_ignore_enabled: false,
      auto_ignore_threshold: 1000,

      # ntfy (https://ntfy.sh) push notifications for new/reopened issues.
      # ntfy_url is the full topic URL (e.g. https://ntfy.sh/my-splat); leave
      # blank to disable.
      ntfy_priority: "default"
    }
  end

  # Helper methods for common retention calculations
  def event_payloads_cutoff_date
    event_payloads_retention_days.days.ago
  end

  def events_data_cutoff_date
    events_data_retention_days.days.ago
  end

  def transaction_measurements_cutoff_date
    transaction_measurements_retention_days.days.ago
  end

  def transactions_data_cutoff_date
    transactions_data_retention_days.days.ago
  end

  def ducklake_events_cutoff_date
    ducklake_events_retention_days.days.ago
  end

  def ducklake_transactions_cutoff_date
    ducklake_transactions_retention_days.days.ago
  end

  def ducklake_issues_cutoff_date
    ducklake_issues_retention_days.days.ago
  end

  def ducklake_spans_cutoff_date
    ducklake_spans_retention_days.days.ago
  end

  def forwarding?
    forward_dsn.present?
  end

  def ntfy_configured?
    ntfy_url.present?
  end

  # Validation
  validates :event_payloads_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 365 }
  validates :events_data_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 365 }
  validates :transaction_measurements_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 365 }
  validates :transactions_data_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 365 }
  validates :ducklake_events_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validates :ducklake_transactions_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validates :ducklake_issues_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validates :ducklake_spans_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validates :auto_ignore_threshold, numericality: { greater_than: 0, less_than_or_equal_to: 1_000_000 }
  validate :forward_dsn_parseable
  validates :ntfy_priority, inclusion: { in: NtfyNotifier::VALID_PRIORITIES }, allow_blank: true
  validate :ntfy_url_parseable

  private

  def forward_dsn_parseable
    return if forward_dsn.blank?

    EnvelopeForwarder.parse_dsn(forward_dsn)
  rescue EnvelopeForwarder::InvalidDsn => e
    errors.add(:forward_dsn, e.message)
  end

  def ntfy_url_parseable
    return if ntfy_url.blank?

    NtfyNotifier.parse_url(ntfy_url)
  rescue NtfyNotifier::InvalidUrl => e
    errors.add(:ntfy_url, e.message)
  end
end
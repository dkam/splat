# frozen_string_literal: true

# Global application settings for data retention and performance
class Setting < ApplicationRecord
  # Singleton pattern - there's only one settings row
  def self.instance
    first || create!(default_settings)
  end

  def self.default_settings
    {
      # Raw-row retention — short, drives the OLTP/show-page surface.
      events_data_retention_days:        30,
      transactions_data_retention_days:  90,
      spans_data_retention_days:         30,
      # Histograms are tiny (50–200 B per row) — keep them long for trend views.
      histograms_retention_days:        540
    }
  end

  def events_data_cutoff_date       = events_data_retention_days.days.ago
  def transactions_data_cutoff_date = transactions_data_retention_days.days.ago
  def spans_data_cutoff_date        = spans_data_retention_days.days.ago
  def histograms_cutoff_date        = histograms_retention_days.days.ago

  def forwarding?
    forward_dsn.present?
  end

  validates :events_data_retention_days,       numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validates :transactions_data_retention_days, numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validates :spans_data_retention_days,        numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validates :histograms_retention_days,        numericality: { greater_than: 0, less_than_or_equal_to: 3650 }
  validate :forward_dsn_parseable

  private

  def forward_dsn_parseable
    return if forward_dsn.blank?

    EnvelopeForwarder.parse_dsn(forward_dsn)
  rescue EnvelopeForwarder::InvalidDsn => e
    errors.add(:forward_dsn, e.message)
  end
end
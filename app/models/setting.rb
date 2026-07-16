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
      events_data_retention_days: 30,
      transactions_data_retention_days: 90,
      spans_data_retention_days: 30,
      # Logs are the highest-volume, shortest-lived data — keep them short.
      logs_data_retention_days: 14,
      # Histograms are tiny (50–200 B per row) — keep them long for trend views.
      histograms_retention_days: 540
    }
  end

  def events_data_cutoff_date = events_data_retention_days.days.ago
  def transactions_data_cutoff_date = transactions_data_retention_days.days.ago
  def spans_data_cutoff_date = spans_data_retention_days.days.ago
  def logs_data_cutoff_date = logs_data_retention_days.days.ago
  def histograms_cutoff_date = histograms_retention_days.days.ago

  def ntfy_configured?
    ntfy_url.present?
  end

  # --- Instance MCP token -----------------------------------------------------
  #
  # Only meaningful without OIDC: with users present, /mcp authenticates per user
  # (see McpToken) and this token stops being accepted, so enabling OIDC retires
  # the shared credential rather than leaving it live and forgotten.
  #
  # ENV["MCP_AUTH_TOKEN"] is separate and always accepted — it's the headless
  # path, and can't be regenerated from a web page.

  # Minted on demand so an instance that never opens the MCP panel never carries
  # a live credential.
  def mcp_token!
    return mcp_token if mcp_token.present?

    reset_mcp_token!
    mcp_token
  end

  def reset_mcp_token!
    update_column(:mcp_token, SecureRandom.hex(32))
    update_column(:mcp_token_last_used_at, nil)
    mcp_token
  end

  # Constant-time, and false for a blank stored token so an instance that has
  # never minted one can't be opened with an empty bearer.
  def mcp_token_matches?(presented)
    return false if presented.blank? || mcp_token.blank?

    ActiveSupport::SecurityUtils.secure_compare(presented, mcp_token)
  end

  # Coarse, like McpToken#touch_last_used! — display only, not worth a write per
  # request from a chatty client.
  def touch_mcp_token_used!
    return if mcp_token_last_used_at.present? && mcp_token_last_used_at > McpToken::TOUCH_AFTER.ago

    update_column(:mcp_token_last_used_at, Time.current)
  end

  validates :events_data_retention_days, numericality: {greater_than: 0, less_than_or_equal_to: 3650}
  validates :transactions_data_retention_days, numericality: {greater_than: 0, less_than_or_equal_to: 3650}
  validates :spans_data_retention_days, numericality: {greater_than: 0, less_than_or_equal_to: 3650}
  validates :logs_data_retention_days, numericality: {greater_than: 0, less_than_or_equal_to: 3650}
  validates :histograms_retention_days, numericality: {greater_than: 0, less_than_or_equal_to: 3650}
  validates :burst_threshold, numericality: {greater_than: 0, less_than_or_equal_to: 1_000_000}
  # 0 means "never expire" — see McpToken#authentication_expired?.
  validates :mcp_token_ttl_days, numericality: {greater_than_or_equal_to: 0, less_than_or_equal_to: 3650}
  validates :ntfy_priority, inclusion: {in: NtfyNotifier::VALID_PRIORITIES}, allow_blank: true
  validate :ntfy_url_parseable

  private

  def ntfy_url_parseable
    return if ntfy_url.blank?

    NtfyNotifier.parse_url(ntfy_url)
  rescue NtfyNotifier::InvalidUrl => e
    errors.add(:ntfy_url, e.message)
  end
end

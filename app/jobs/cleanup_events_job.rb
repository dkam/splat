class CleanupEventsJob < ApplicationJob
  def perform
    event_retention_days = fetch_retention_days('SPLAT_MAX_EVENT_LIFE_DAYS', 90)
    transaction_retention_days = fetch_retention_days('SPLAT_MAX_TRANSACTION_EVENT_LIFE_DAYS', 90)
    file_retention_days = fetch_retention_days('SPLAT_MAX_FILE_LIFE_DAYS', 90)

    Rails.logger.info "Starting cleanup: events=#{event_retention_days}d, transactions=#{transaction_retention_days}d, files=#{file_retention_days}d"

    # Clean old events
    deleted_events = Event.where("timestamp < ?", event_retention_days.days.ago).delete_all
    Rails.logger.info "Deleted #{deleted_events} old events"

    # Clean old transactions
    deleted_transactions = Transaction.where("timestamp < ?", transaction_retention_days.days.ago).delete_all
    Rails.logger.info "Deleted #{deleted_transactions} old transactions"

    # Clean empty issues (issues with no events after cleanup)
    empty_issues = Issue.where.missing(:events)
    deleted_issues = empty_issues.delete_all
    Rails.logger.info "Deleted #{deleted_issues} empty issues"

    # Clean empty transaction groups (if you implement transaction groups)
    # This can be added later if you implement transaction grouping

    Rails.logger.info "Cleanup completed successfully"
  end

  private

  def fetch_retention_days(env_var, default_days)
    value = ENV.fetch(env_var, default_days.to_s)
    return default_days if value.blank?

    days = value.to_i
    days.positive? ? days : default_days
  rescue ArgumentError, TypeError
    Rails.logger.warn "Invalid #{env_var} value: #{value.inspect}, using default #{default_days} days"
    default_days
  end
end
# frozen_string_literal: true

# Data retention cleanup job
# Removes old payloads/measurements and deletes records according to retention settings
class DataRetentionJob < ApplicationJob
  queue_as :low_priority

  BATCH_SIZE = 500
  SLEEP_BETWEEN_BATCHES = 0.1

  def perform
    Rails.logger.info "Starting data retention cleanup"
    start_time = Time.current
    setting = Setting.instance

    # 1. Clean up old event payloads (set to NULL)
    payload_cleanup_count = batched_update_all(
      Event.where("timestamp < ?", setting.event_payloads_cutoff_date).where.not(payload: nil),
      payload: nil
    )

    # 2. Clean up old transaction measurements (set to NULL)
    measurements_cleanup_count = batched_update_all(
      Transaction.where("timestamp < ?", setting.transaction_measurements_cutoff_date).where.not(measurements: nil),
      measurements: nil
    )

    # 3. Delete very old event records
    events_deleted_count = batched_delete_all(
      Event.where("timestamp < ?", setting.events_data_cutoff_date)
    )

    # 4. Delete very old transaction records
    transactions_deleted_count = batched_delete_all(
      Transaction.where("timestamp < ?", setting.transactions_data_cutoff_date)
    )

    duration = Time.current - start_time

    Rails.logger.info "Data retention cleanup completed in #{duration.round(2)}s:"
    Rails.logger.info "  - Event payloads cleared: #{payload_cleanup_count}"
    Rails.logger.info "  - Transaction measurements cleared: #{measurements_cleanup_count}"
    Rails.logger.info "  - Old events deleted: #{events_deleted_count}"
    Rails.logger.info "  - Old transactions deleted: #{transactions_deleted_count}"

    # Return summary for potential notification
    {
      duration: duration,
      payload_cleanup_count: payload_cleanup_count,
      measurements_cleanup_count: measurements_cleanup_count,
      events_deleted_count: events_deleted_count,
      transactions_deleted_count: transactions_deleted_count
    }
  end

  private

  def batched_update_all(scope, attrs)
    total = 0
    scope.in_batches(of: BATCH_SIZE) do |batch|
      total += batch.update_all(attrs)
      sleep SLEEP_BETWEEN_BATCHES
    end
    total
  end

  def batched_delete_all(scope)
    total = 0
    scope.in_batches(of: BATCH_SIZE) do |batch|
      total += batch.delete_all
      sleep SLEEP_BETWEEN_BATCHES
    end
    total
  end
end
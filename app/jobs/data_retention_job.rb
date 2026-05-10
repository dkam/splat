# frozen_string_literal: true

# Data retention cleanup job
# Removes old payloads/measurements and deletes records according to retention settings
class DataRetentionJob
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

    # 3. Delete very old event records (delete_all skips counter_cache;
    #    we snapshot affected issues and recount them after the deletes).
    events_scope = Event.where("timestamp < ?", setting.events_data_cutoff_date)
    affected_issue_ids = events_scope.distinct.pluck(:issue_id).compact
    events_deleted_count = batched_delete_all(events_scope)
    recount_issues(affected_issue_ids)

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

  def recount_issues(issue_ids)
    return if issue_ids.empty?
    issue_ids.each_slice(BATCH_SIZE) do |batch|
      Issue.where(id: batch).update_all(
        "count = (SELECT COUNT(*) FROM events WHERE events.issue_id = issues.id)"
      )
      sleep SLEEP_BETWEEN_BATCHES
    end
  end
end

# frozen_string_literal: true

class ProcessTransactionJob < ApplicationJob
  queue_as :default

  def perform(transaction_id:, payload:, project:)
    # Create the transaction record from Sentry payload
    transaction = Transaction.create_from_sentry_payload!(transaction_id, payload, project)

    Rails.logger.info "Processed transaction #{transaction.id}: #{transaction.transaction_name} (#{transaction.duration}ms)"
  rescue => e
    # Log but don't fail - performance data is nice-to-have
    Rails.logger.error "Failed to process transaction #{transaction_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    # Don't raise - we don't want transaction processing failures to block error processing
  end
end

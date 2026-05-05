# frozen_string_literal: true

class ProcessTransactionJob < ApplicationJob
  queue_as :default

  def perform(transaction_id:, payload:, project:)
    # Create the transaction record from Sentry payload
    transaction = Transaction.create_from_sentry_payload!(transaction_id, payload, project)

    if transaction.release.present?
      Release.record_sighting!(project: project, version: transaction.release,
                               timestamp: transaction.timestamp, kind: :transaction)
    end

    mirror_to_ducklake(transaction)

    Rails.logger.info "Processed transaction #{transaction.id}: #{transaction.transaction_name} (#{transaction.duration}ms)"
  rescue => e
    # Log but don't fail - performance data is nice-to-have
    Rails.logger.error "Failed to process transaction #{transaction_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    # Don't raise - we don't want transaction processing failures to block error processing
  end

  private

  # AR is the source of truth. DuckLake mirrors for analytics; failures here
  # must not break ingestion.
  def mirror_to_ducklake(transaction)
    DuckLake::Transaction.insert(
      id: transaction.id,
      transaction_id: transaction.transaction_id,
      project_id: transaction.project_id,
      timestamp: transaction.timestamp,
      transaction_name: transaction.transaction_name,
      op: transaction.op,
      duration: transaction.duration,
      db_time: transaction.db_time,
      view_time: transaction.view_time,
      environment: transaction.environment,
      release: transaction.release,
      server_name: transaction.server_name,
      http_method: transaction.http_method,
      http_status: transaction.http_status,
      http_url: transaction.http_url,
      tags: transaction.tags,
      measurements: transaction.measurements,
      created_at: transaction.created_at,
      updated_at: transaction.updated_at
    )
  rescue => e
    Rails.logger.error "[DuckLake] transaction mirror failed (#{transaction.transaction_id}): #{e.class}: #{e.message}"
  end
end

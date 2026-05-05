# frozen_string_literal: true

class ProcessEventJob < ApplicationJob
  queue_as :default

  def perform(event_id:, payload:, project:)
    event = Event.create_from_sentry_payload!(event_id, payload, project)

    if event.issue
      event.issue.open! if event.issue.resolved?
      # `count` is maintained by counter_cache on Event#belongs_to :issue.
      Issue.where(id: event.issue.id).update_all(last_seen: event.timestamp)
    end

    mirror_to_ducklake(event)

    Rails.logger.info "Processed event #{event.id}: #{event.exception_type}"
  rescue ActiveRecord::RecordNotUnique
    # Duplicate event_id - another worker already processed this event. Idempotent.
    Rails.logger.info "Duplicate event #{event_id} skipped"
  rescue => e
    Rails.logger.error "Failed to process event #{event_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  private

  # AR is the source of truth. DuckLake mirrors for analytics; failures here
  # must not break ingestion.
  def mirror_to_ducklake(event)
    DuckLake::Event.insert(
      id: event.id,
      event_id: event.event_id,
      project_id: event.project_id,
      issue_id: event.issue_id,
      timestamp: event.timestamp,
      duration: event.duration,
      environment: event.environment,
      exception_type: event.exception_type,
      exception_value: event.exception_value,
      fingerprint: event.fingerprint.is_a?(Array) ? event.fingerprint.join("::") : event.fingerprint,
      message: event.message,
      platform: event.platform,
      release: event.release,
      sdk_name: event.sdk_name,
      sdk_version: event.sdk_version,
      server_name: event.server_name,
      transaction_name: event.transaction_name,
      payload: event.payload,
      created_at: event.created_at,
      updated_at: event.updated_at
    )

    if event.issue
      issue = event.issue
      DuckLake::Issue.insert(
        id: issue.id,
        project_id: issue.project_id,
        fingerprint: issue.fingerprint,
        title: issue.title,
        exception_type: issue.exception_type,
        status: Issue.statuses[issue.status],
        count: issue.count,
        first_seen: issue.first_seen,
        last_seen: issue.last_seen,
        created_at: issue.created_at,
        updated_at: issue.updated_at
      )
    end
  rescue => e
    Rails.logger.error "[DuckLake] event mirror failed (#{event.event_id}): #{e.class}: #{e.message}"
  end

  end

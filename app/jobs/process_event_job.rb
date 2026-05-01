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

    Rails.logger.info "Processed event #{event.id}: #{event.exception_type}"
  rescue ActiveRecord::RecordNotUnique
    # Duplicate event_id - another worker already processed this event. Idempotent.
    Rails.logger.info "Duplicate event #{event_id} skipped"
  rescue => e
    Rails.logger.error "Failed to process event #{event_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  end

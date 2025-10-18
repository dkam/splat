# frozen_string_literal: true

class ProcessEventJob < ApplicationJob
  queue_as :default

  def perform(event_id:, payload:, project:)
    # Skip if we've already processed this exact event (idempotency)
    return if Event.exists?(event_id: event_id)

    # Create the event record from Sentry payload
    event = Event.create_from_sentry_payload!(event_id, payload, project)

    # Update the issue statistics with the event's actual timestamp
    if event.issue
      event.issue.update!(
        count: event.issue.count + 1,
        last_seen: event.timestamp
      )
    end

    Rails.logger.info "Processed event #{event.id}: #{event.exception_type}"
  rescue => e
    Rails.logger.error "Failed to process event #{event_id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end
end

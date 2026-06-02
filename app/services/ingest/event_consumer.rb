# frozen_string_literal: true

module Ingest
  # Drains splat.events, runs AR create_from_sentry_payload! per row.
  # The single write goes straight into storage/<env>_issues_events.sqlite3
  # via the IssuesEventsRecord base — no cold-tier fan-out anymore.
  class EventConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::EVENTS_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      outcomes = []

      jobs.each do |job|
        args = JSON.parse(job.body)
        project = project_for(args["project_id"])
        unless project
          Rails.logger.warn "[#{self.class.name}] dropping job for missing project_id=#{args["project_id"]}"
          outcomes << [job, :ok]
          next
        end

        Event.create_from_sentry_payload!(args["event_id"], args["payload"], project)
        outcomes << [job, :ok]
      rescue ActiveRecord::RecordNotUnique
        outcomes << [job, :ok]
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        outcomes << [job, :retry]
      end

      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end
  end
end

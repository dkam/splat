# frozen_string_literal: true

module Ingest
  # Stage 1 events: drain splat.events, run AR create_from_sentry_payload!
  # per row (preserving counter_cache, validations, after_create_commit
  # broadcasts), then push hydrated rows downstream to the DuckLake mirror
  # tubes. No DuckLake writes happen in this process.
  class EventConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::EVENTS_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      events = []
      issues = {}
      outcomes = []

      jobs.each do |job|
        args = JSON.parse(job.body)
        project = project_for(args["project_id"])
        unless project
          Rails.logger.warn "[#{self.class.name}] dropping job for missing project_id=#{args["project_id"]}"
          outcomes << [job, :ok]
          next
        end

        event = Event.create_from_sentry_payload!(args["event_id"], args["payload"], project)
        events << event
        issues[event.issue_id] = event.issue if event.issue
        outcomes << [job, :ok]
      rescue ActiveRecord::RecordNotUnique
        outcomes << [job, :ok]
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        outcomes << [job, :retry]
      end

      forward_to_mirror(events, issues.values)
      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end

    # One body per tube per batch — beanstalkd has no batch put, so packing
    # collapses N RTTs to 1. Stage 2 unpacks via the {rows: [...]} convention.
    # `table:` lets UnifiedConsumer dispatch to the right model without
    # paying STATS-JOB per body to recover the tube name.
    def forward_to_mirror(events, issues)
      if events.any?
        Tuber.put(Tuber::DUCKLAKE_EVENTS_TUBE,
                  { table: "events", rows: events.map(&:to_ducklake_row) })
      end
      if issues.any?
        Tuber.put(Tuber::DUCKLAKE_ISSUES_TUBE,
                  { table: "issues", rows: issues.map(&:to_ducklake_row) })
      end
    rescue => e
      log_exception("[#{self.class.name}] mirror forward failed", e)
    end
  end
end

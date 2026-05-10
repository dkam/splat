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
          Rails.logger.warn "[Ingest::EventConsumer] dropping job for missing project_id=#{args["project_id"]}"
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
        Rails.logger.error "[Ingest::EventConsumer] job failed: #{e.class}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        outcomes << [job, :retry]
      end

      forward_to_mirror(events, issues.values)
      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end

    def forward_to_mirror(events, issues)
      events.each { |e| Tuber.put(Tuber::DUCKLAKE_EVENTS_TUBE, event_row(e)) }
      issues.each { |i| Tuber.put(Tuber::DUCKLAKE_ISSUES_TUBE, issue_row(i)) }
    rescue => e
      Rails.logger.error "[Ingest::EventConsumer] mirror forward failed: #{e.class}: #{e.message}"
    end

    def project_for(id)
      @project_cache ||= {}
      @project_cache[id] ||= Project.find_by(id: id)
    end

    def event_row(event)
      {
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
      }
    end

    def issue_row(issue)
      {
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
      }
    end
  end
end

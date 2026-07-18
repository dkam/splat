# frozen_string_literal: true

module Ingest
  # Drains splat.checkins. Two body shapes share the tube deliberately:
  #
  #   { "payload": {...}, "project_id": N }   — a check-in from the envelope
  #                                             path; upserts the Monitor row.
  #   { "class": "...", "args": [...] }       — a scheduler dispatch body;
  #                                             runs Monitors::EvaluateJob.
  #
  # The evaluator lives here rather than on splat.maintenance because the
  # maintenance tube serialises behind heavy jobs (the storage deep pass runs
  # for the better part of an hour) — a dead-man's-switch alert can't wait
  # behind a page walk. Sharing one consumer also serialises check-in writes
  # with evaluation, so the sweep never races an in-flight upsert.
  class CheckInConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::CHECKINS_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      outcomes = []

      jobs.each do |job|
        body = JSON.parse(job.body)

        if body["class"]
          body["class"].constantize.new.perform(*(body["args"] || []))
        else
          project = project_for(body["project_id"])
          if project
            CronMonitor.record_check_in!(body["payload"], project)
          else
            Rails.logger.warn "[#{self.class.name}] dropping check-in for missing project_id=#{body["project_id"]}"
          end
        end
        outcomes << [job, :ok]
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        outcomes << [job, :retry]
      end

      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end
  end
end

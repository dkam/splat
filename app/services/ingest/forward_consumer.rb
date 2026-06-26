# frozen_string_literal: true

require "base64"

module Ingest
  # Drains splat.forward, mirroring each raw envelope to every downstream DSN
  # the project has configured (Project#forward_dsns). Delivery is best-effort:
  # per-DSN failures are logged inside EnvelopeForwarder.deliver but the job is
  # always finalized :ok, so a flaky downstream never re-sends to the targets
  # that already succeeded.
  class ForwardConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::FORWARD_TUBE, batch_size: batch_size)
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

        raw_body = Base64.strict_decode64(args["body"].to_s)
        content_type = args["content_type"] || "application/x-sentry-envelope"

        Array(args["dsns"]).each do |dsn|
          EnvelopeForwarder.deliver(raw_body, dsn: dsn, project: project, content_type: content_type)
        end

        outcomes << [job, :ok]
      rescue => e
        # Even on an unexpected error we finalize :ok — forwarding is
        # best-effort and a malformed job body would otherwise cycle forever.
        log_exception("[#{self.class.name}] job failed", e)
        outcomes << [job, :ok]
      end

      outcomes.each { |job, outcome| safe_finalize(job, outcome) }
    end
  end
end

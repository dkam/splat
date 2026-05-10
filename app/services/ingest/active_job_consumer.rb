# frozen_string_literal: true

module Ingest
  # Drains splat.activejob and runs each payload through ActiveJob::Base.execute.
  # Mailers (ActionMailer's MailDeliveryJob) and any other deliver_later /
  # perform_later flow through here.
  class ActiveJobConsumer < TubeConsumer
    def initialize(batch_size: 10)
      super(tube: Tuber::ACTIVEJOB_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      jobs.each do |job|
        body = JSON.parse(job.body)
        ActiveJob::Base.execute(body["activejob"])
        job.delete
      rescue Beaneater::NotFoundError
        nil
      rescue => e
        log_exception("[#{self.class.name}] job failed", e)
        safe_finalize(job, :retry)
      end
    end
  end
end

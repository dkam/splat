# frozen_string_literal: true

module Ingest
  # Drains a tube whose bodies look like `{ "class": "Foo::BarJob", "args": [...] }`,
  # instantiates the class, and calls `#perform(*args)`. Used for the
  # splat.maintenance tube where the scheduler pushes recurring jobs.
  class DispatchConsumer < TubeConsumer
    def initialize(tube:, batch_size: 10)
      super
    end

    private

    def process_batch(jobs)
      jobs.each do |job|
        klass_name = nil
        body = JSON.parse(job.body)
        klass_name = body["class"]
        args = body["args"] || []
        klass_name.constantize.new.perform(*args)
        job.delete
      rescue Beaneater::NotFoundError
        nil
      rescue => e
        log_exception("[#{self.class.name}] #{klass_name || "?"} failed", e)
        safe_finalize(job, :retry)
      end
    end
  end
end

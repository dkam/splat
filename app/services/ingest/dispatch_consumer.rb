# frozen_string_literal: true

module Ingest
  # Drains a tube whose bodies look like `{ "class": "Foo::BarJob", "args": [...] }`,
  # instantiates the class, and calls `#perform(*args)`. Used for maintenance
  # tubes — both the AR side (splat.maintenance) and the DuckLake side
  # (splat.ducklake.maintenance), since dispatch is identical and only the
  # tube + which worker watches it differs.
  class DispatchConsumer < TubeConsumer
    def initialize(tube:, batch_size: 10)
      super(tube: tube, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      jobs.each do |job|
        body = JSON.parse(job.body)
        klass_name = body["class"]
        args = body["args"] || []
        klass_name.constantize.new.perform(*args)
        job.delete
      rescue Beaneater::NotFoundError
        nil
      rescue => e
        Rails.logger.error "[Ingest::DispatchConsumer] #{klass_name || '?'} failed: #{e.class}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        safe_finalize(job, :retry)
      end
    end
  end
end

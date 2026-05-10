# frozen_string_literal: true

require "active_job/queue_adapters/abstract_adapter"

module ActiveJob
  module QueueAdapters
    # Puts ActiveJob payloads onto a single tuber tube. The maintenance
    # consumer drains it and calls ActiveJob::Base.execute, which runs the
    # job class normally — mailers and any other deliver_later use this path.
    class TuberAdapter < AbstractAdapter
      def enqueue(job)
        ::Ingest::Tuber.put(::Ingest::Tuber::ACTIVEJOB_TUBE,
                            { activejob: job.serialize, queue: job.queue_name })
      end

      def enqueue_at(job, timestamp)
        delay = (timestamp - Time.current.to_f).round
        delay = 0 if delay < 0
        ::Ingest::Tuber.put(::Ingest::Tuber::ACTIVEJOB_TUBE,
                            { activejob: job.serialize, queue: job.queue_name },
                            delay: delay)
      end
    end
  end
end

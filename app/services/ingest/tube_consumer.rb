# frozen_string_literal: true

module Ingest
  # Common loop + shutdown plumbing for any tuber consumer. Subclasses
  # implement #process_batch(jobs); the base handles reserve_batch, the timeout
  # case, and the stop flag.
  class TubeConsumer
    DEFAULT_BATCH_SIZE = 100
    RETRY_DELAY = 5

    attr_reader :tube, :batch_size

    def initialize(tube:, batch_size: DEFAULT_BATCH_SIZE)
      @tube = tube
      @batch_size = batch_size
      @client = Tuber.consumer_client
      @client.tubes.watch!(tube)
      @stop = false
    end

    def stop!
      @stop = true
    end

    def run
      until @stop
        process_one_batch
      end
    ensure
      @client.close rescue nil
    end

    def process_one_batch
      jobs = reserve_batch
      return if jobs.empty?

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      process_batch(jobs)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      Rails.logger.info "[#{self.class.name}] processed #{jobs.size} in #{ms}ms"
    end

    private

    def reserve_batch
      @client.tubes.reserve_batch(@batch_size)
    rescue Beaneater::TimedOutError
      []
    end

    # Override.
    def process_batch(jobs)
      raise NotImplementedError
    end

    # Helpers shared by all subclasses.

    def safe_finalize(job, outcome)
      case outcome
      when :ok    then job.delete
      when :retry then job.release(delay: RETRY_DELAY)
      end
    rescue Beaneater::NotFoundError
      # Already gone server-side — nothing to do.
    end
  end
end

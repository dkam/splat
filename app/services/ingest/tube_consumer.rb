# frozen_string_literal: true

module Ingest
  # Common loop + shutdown plumbing for any tuber consumer. Subclasses
  # implement #process_batch(jobs); the base handles reserve_batch, the timeout
  # case, and the stop flag.
  class TubeConsumer
    DEFAULT_BATCH_SIZE = 100
    RETRY_DELAY = 5

    # When the tubes are empty, park on a single blocking reserve for this many
    # seconds rather than hot-looping on the non-blocking reserve-batch. The
    # timeout bounds the park so the loop still wakes periodically to honour the
    # @stop flag for graceful shutdown.
    RESERVE_TIMEOUT = 30

    # Bury rather than release once a job has been re-tried this many times,
    # so a poison-pill body doesn't cycle on the tube forever.
    MAX_RETRIES = 5

    attr_reader :tube, :batch_size

    def initialize(tube:, batch_size: DEFAULT_BATCH_SIZE)
      @tube = tube
      @batch_size = batch_size
      @stop = false
    end

    def stop!
      @stop = true
    end

    def run
      # Open the connection and WATCH on the same thread that reserves.
      # Beaneater connections are per-thread: a watch! issued on the
      # constructing thread doesn't apply to the socket this thread reserves
      # on, so the worker would silently reserve from `default` (empty) and
      # never drain its tube. Each thread owning its own connection keeps the
      # watched-tube state on the socket doing the work.
      @client = Tuber.consumer_client
      @client.tubes.watch!(@tube)
      Rails.logger.info "[#{self.class.name}] watching #{@tube}"

      until @stop
        begin
          process_one_batch
        rescue => e
          log_exception("[#{self.class.name}] loop error (continuing)", e)
          sleep 1
        end
      end
    ensure
      begin
        @client&.close
      rescue
        nil
      end
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
      jobs = @client.tubes.reserve_batch(@batch_size)
      return jobs unless jobs.empty?

      # Tubes are empty: tuber's reserve-batch returns RESERVED_BATCH 0
      # immediately, so looping on it busy-spins the CPU. Park on a single
      # blocking reserve-with-timeout instead — it returns the instant a job
      # lands, and the next iteration sweeps any siblings back up as a full
      # batch.
      [@client.tubes.reserve(RESERVE_TIMEOUT)]
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
      when :ok then job.delete
      when :retry then bury_or_release(job)
      end
    rescue Beaneater::NotFoundError
      # Already gone server-side — nothing to do.
    end

    def bury_or_release(job)
      releases = begin
        job.stats.releases.to_i
      rescue
        0
      end
      if releases >= MAX_RETRIES
        Rails.logger.error "[#{self.class.name}] burying job after #{releases} retries"
        job.bury
      else
        job.release(delay: RETRY_DELAY)
      end
    end

    def log_exception(prefix, e)
      Rails.logger.error "#{prefix}: #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
    end

    def project_for(id)
      @project_cache ||= {}
      @project_cache[id] ||= Project.find_by(id: id)
    end
  end
end

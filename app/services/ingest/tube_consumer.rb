# frozen_string_literal: true

module Ingest
  # Common loop + shutdown plumbing for any tuber consumer. Subclasses
  # implement #process_batch(jobs); the base handles reserve_batch, the timeout
  # case, and the stop flag.
  class TubeConsumer
    DEFAULT_BATCH_SIZE = 100
    RETRY_DELAY = 5

    # When the tubes are empty, long-poll the batch reserve for this many
    # seconds (the server parks the waiter) rather than hot-looping. The
    # timeout bounds the park so the loop still wakes periodically to honour the
    # @stop flag for graceful shutdown.
    RESERVE_TIMEOUT = 30

    # Bury rather than release once a job has been re-tried this many times,
    # so a poison-pill body doesn't cycle on the tube forever.
    MAX_RETRIES = 5

    # How often to touch the jobs a batch is still working on. A job's TTR is
    # the server's "is this worker still alive?" timer: hold a job longer than
    # its TTR without touching and tuber assumes the worker died, and makes the
    # job ready for someone else — while this worker is still busy with it.
    #
    # Not theoretical. Maintenance::StorageStatsJob's deep pass walks every page
    # of every DB (~40 minutes on a 114 GB instance) against the 120s
    # Tuber::DEFAULT_TTR. It was requeued ~20x per run, then re-reserved the
    # moment it finished (its own delete had already become a no-op NotFound),
    # and re-run forever — starving splat.maintenance, which is where
    # Maintenance::RetentionJob lives. A database that never purges because its
    # stats job is too slow to measure it.
    #
    # Must stay comfortably under the shortest TTR any producer uses
    # (Tuber::DEFAULT_TTR is 120s). Touching early is free; touching late isn't.
    TOUCH_INTERVAL = 30

    # Seconds to wait between attempts to (re)connect to tuber. The worker
    # retries for as long as it takes — on boot it waits for tuber to come up,
    # and after a tuber restart it reconnects and re-watches its tube — so a
    # worker started before tuber (or one whose tuber gets bounced) recovers on
    # its own instead of dying. A worker with no live tuber has nothing to do
    # but wait, so there's no point crashing out; @stop still breaks the wait
    # promptly for a clean shutdown.
    CONNECT_RETRY_INTERVAL = 2

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
      # Wait for tuber before entering the loop — a worker may boot before
      # tuber is up (or with tuber briefly gone). connect! opens the connection
      # and WATCHes on the same thread that reserves: beaneater connections are
      # per-thread, so a watch! issued on another thread wouldn't apply to the
      # socket this thread reserves on, and the worker would silently reserve
      # from `default` (empty) and never drain its tube.
      return unless connect_with_retry

      until @stop
        begin
          process_one_batch
        rescue *Tuber::CONNECTION_ERRORS => e
          # Tuber went away mid-loop (a restart outlasting beaneater's own
          # in-command retries). Rebuild the connection — this re-WATCHes the
          # tube — and carry on; in-flight jobs are re-reserved after their TTR.
          log_exception("[#{self.class.name}] tuber connection lost, reconnecting", e)
          break unless reconnect
        rescue => e
          log_exception("[#{self.class.name}] loop error (continuing)", e)
          sleep 1
        end
      end
    ensure
      close_client
    end

    def process_one_batch
      jobs = reserve_batch
      return if jobs.empty?

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      keeping_alive(jobs) { process_batch(jobs) }
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      Rails.logger.info "[#{self.class.name}] processed #{jobs.size} in #{ms}ms"
    end

    # Run the block with a heartbeat touching `jobs`, so a batch slower than its
    # TTR keeps the reservations it's still working on (see TOUCH_INTERVAL).
    #
    # The heartbeat shares this consumer's connection deliberately: a
    # reservation belongs to the connection that made it, so a touch from any
    # other socket is NOT_FOUND. Beaneater serialises commands on that
    # connection's mutex, and nothing reserves while a batch is in flight, so
    # the touch only ever contends with this batch's own deletes.
    def keeping_alive(jobs)
      # A queue rather than a flag + sleep: pop(timeout:) waits the full
      # interval but wakes the instant the batch finishes, so `ensure` never
      # blocks waiting for a nap to end.
      finished = Queue.new
      heartbeat = Thread.new do
        until finished.pop(timeout: touch_interval)
          jobs.each do |job|
            job.touch
          rescue
            # Already deleted, expired, or never reserved — nothing left to keep
            # alive. process_batch owns what happens to the job itself; a failed
            # touch is only ever a lost cause, never a new problem.
            nil
          end
        end
      end
      yield
    ensure
      finished&.push(true)
      # join, not kill: killing mid-touch would abandon a half-written command
      # on the shared socket and desync the protocol for every later reserve.
      heartbeat&.join(TOUCH_INTERVAL)
    end

    # Overridable so tests can drive the heartbeat without waiting on the wall
    # clock. A subclass can't just redefine TOUCH_INTERVAL — Ruby resolves
    # constants lexically, so the reference above would still find this class's.
    def touch_interval = TOUCH_INTERVAL

    private

    # Try to connect and WATCH the tube, retrying every CONNECT_RETRY_INTERVAL
    # until it succeeds or @stop is set. Returns true once watching, false if
    # asked to shut down before tuber ever became reachable.
    def connect_with_retry
      attempt = 0
      until @stop
        begin
          @client = Tuber.consumer_client
          @client.tubes.watch!(@tube)
          Rails.logger.info "[#{self.class.name}] watching #{@tube}"
          return true
        rescue => e
          attempt += 1
          Rails.logger.warn(
            "[#{self.class.name}] waiting for tuber (attempt #{attempt}): #{e.class}: #{e.message}"
          )
          interruptible_sleep(CONNECT_RETRY_INTERVAL)
        end
      end
      false
    end

    def reconnect
      close_client
      connect_with_retry
    end

    def close_client
      @client&.close
    rescue
      # A dead socket can raise on close; we only care that it's released.
    ensure
      @client = nil
    end

    # Sleep in one-second slices so a SIGTERM (which sets @stop) breaks the wait
    # promptly instead of blocking a full interval.
    def interruptible_sleep(seconds)
      remaining = seconds
      while remaining > 0 && !@stop
        sleep 1
        remaining -= 1
      end
    end

    def reserve_batch
      # One blocking call: long-poll up to RESERVE_TIMEOUT for the first job,
      # then drain every sibling that's ready up to @batch_size. When the tube
      # stays empty the server parks the waiter and returns an empty
      # RESERVED_BATCH (not TIMED_OUT), so we get [] back and the loop wakes
      # to honour @stop.
      @client.tubes.reserve_batch(@batch_size, RESERVE_TIMEOUT)
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

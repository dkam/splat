# frozen_string_literal: true

module Ingest
  # Jobs tuber couldn't take, kept on disk until it can. An SDK drops an
  # envelope after a 5xx rather than sending it again, so with tuber down the
  # only way not to lose it is to keep it here: the ingest endpoints answer 200
  # once a job is spooled, and 503 only when the spool can't take it either.
  #
  # One file per job, in storage/spool on the volume the web and worker
  # containers share; Ingest::SpoolReplayer, in the worker, puts them back in
  # order once tuber answers. Bounded by SPLAT_SPOOL_MAX_MB (default 1024), so
  # a long outage can't fill the disk the databases live on; 0 turns spooling
  # off.
  #
  # Replay is at least once: a worker that dies between tuber taking a job and
  # the file going sends it again. Events are unique on event_id; a transaction
  # or log could land twice.
  module Spool
    # No room: past the cap, or the disk refused the write.
    class Full < StandardError; end

    SUFFIX = ".job"

    # The cap is checked against a running tally rather than a walk of the
    # directory on every write, which an outage would make slow just when
    # writes are most frequent. Recounted from disk this often, since other
    # processes write and the replayer removes.
    RECOUNT_INTERVAL = 10

    MUTEX = Mutex.new

    class << self
      attr_writer :dir, :max_bytes

      def dir
        Pathname(@dir || ENV.fetch("SPLAT_SPOOL_DIR") { Rails.root.join("storage", "spool").to_s })
      end

      def max_bytes
        @max_bytes || Integer(ENV.fetch("SPLAT_SPOOL_MAX_MB", "1024")) * 1.megabyte
      end

      # Queues the job, or spools it when tuber can't be reached: :queued or
      # :spooled. Raises Full when it can do neither.
      def put(tube, payload)
        Tuber.put(tube, payload)
        :queued
      rescue *Tuber::CONNECTION_ERRORS
        write(tube, payload)
        :spooled
      end

      # Puts every spooled job back, oldest first, removing each once tuber has
      # it. Stops at the first sign tuber has gone again. Returns how many went.
      def replay
        replayed = 0
        files.each do |path|
          job = JSON.parse(File.binread(path))
          Tuber.put(job.fetch("tube"), job.fetch("payload"))
          remove(path)
          replayed += 1
        rescue Errno::ENOENT
          next
        rescue ::Tuber::JobTooBigError, JSON::ParserError, KeyError => e
          # Refused every time it's tried, so kept it would hold up the rest.
          Rails.logger.warn("[Spool] dropped #{path.basename}: #{e.class} #{e.message}")
          remove(path)
        end
        replayed
      rescue *Tuber::CONNECTION_ERRORS
        replayed
      end

      def stats
        sizes = files.filter_map { File.size?(it) }
        {jobs: sizes.size, bytes: sizes.sum}
      end

      private

      def write(tube, payload)
        body = JSON.generate({tube: tube, payload: payload})
        partial = nil
        MUTEX.synchronize do
          if tally + body.bytesize > max_bytes
            raise Full, "spool is full (#{max_bytes / 1.megabyte} MB, SPLAT_SPOOL_MAX_MB)"
          end

          dir.mkpath
          # Sorts by time; renamed into place whole, so the replayer never
          # reads half a file.
          name = "#{Time.now.utc.strftime("%Y%m%dT%H%M%S%6N")}-#{SecureRandom.hex(4)}"
          partial = dir.join("#{name}.partial")
          File.binwrite(partial, body)
          File.rename(partial, dir.join("#{name}#{SUFFIX}"))
          @tally += body.bytesize
        end
      rescue SystemCallError, IOError => e
        File.delete(partial) if partial && File.exist?(partial)
        raise Full, "spool can't be written: #{e.message}"
      end

      def files = dir.glob("*#{SUFFIX}").sort

      def remove(path)
        File.delete(path)
      rescue Errno::ENOENT
        nil
      end

      def tally
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @tallied_at.nil? || @tallied_dir != dir || now - @tallied_at > RECOUNT_INTERVAL
          @tally = stats[:bytes]
          @tallied_at = now
          @tallied_dir = dir
        end
        @tally
      end
    end
  end
end

# frozen_string_literal: true

module Ingest
  module Tuber
    EVENTS_TUBE = "splat.events"
    TRANSACTIONS_TUBE = "splat.transactions"
    LOGS_TUBE = "splat.logs"
    FORWARD_TUBE = "splat.forward"
    MAINTENANCE_TUBE = "splat.maintenance"
    ACTIVEJOB_TUBE = "splat.activejob"

    # Every pipeline tube, in display order. (INGEST_TUBES, used for the single
    # backlog number, intentionally omits logs; this is the full per-tube view.)
    ALL_TUBES = [
      EVENTS_TUBE, TRANSACTIONS_TUBE, LOGS_TUBE,
      FORWARD_TUBE, ACTIVEJOB_TUBE, MAINTENANCE_TUBE
    ].freeze

    # TTR covers one full message round-trip (AR write into the cluster DB
    # plus any per-row work). With dictionary-compressed inserts and no
    # secondary cold-tier fan-out, processing is well under a second;
    # 120s leaves headroom before tuber re-releases the message.
    DEFAULT_TTR = 120
    DEFAULT_PRI = 1024

    # A dead socket: tuber was restarted or bounced under us. Beaneater retries
    # these a few times inside a single command and then gives up with
    # NotConnected — at which point the cached connection is holding a closed
    # socket that never heals on its own. Consumers (TubeConsumer) and the
    # producer helper below both key off this list to rebuild the connection.
    CONNECTION_ERRORS = [
      ::Beaneater::NotConnected, Errno::ECONNREFUSED, Errno::ECONNRESET,
      Errno::EPIPE, EOFError, IOError, SocketError
    ].freeze

    class << self
      def address
        ENV.fetch("TUBER_URL", "localhost:11330")
      end

      # One producer client per thread. Beaneater serialises commands through
      # an internal mutex, but a per-thread connection avoids contending Puma
      # workers on the same socket.
      def producer
        Thread.current[:ingest_tuber_producer] ||= ::Beaneater.new(address)
      end

      # Throw the per-thread connection away so the next #producer rebuilds it.
      def reset_producer!
        Thread.current[:ingest_tuber_producer]&.close
      rescue
        # Closing a dead socket can itself raise; we only care that it's gone.
      ensure
        Thread.current[:ingest_tuber_producer] = nil
      end

      # Run a block against the per-thread producer, rebuilding the connection
      # once if it turns out to be dead. Lets producers (web ingest puts, the
      # scheduler, ActiveJob enqueues) transparently survive tuber restarting:
      # one clean retry against a fresh connection, then the error propagates
      # to the caller. Fail-fast, not a blocking wait — a web request must not
      # hang on a down queue.
      def with_producer
        tries = 0
        begin
          yield producer
        rescue *CONNECTION_ERRORS
          reset_producer!
          tries += 1
          retry if tries < 2
          raise
        end
      end

      # con: / idp: are tuber server extensions (per-key concurrency cap +
      # idempotency suppression). Tuber rejects unknown opts on vanilla
      # beanstalkd, so callers omit them unless they want the behavior.
      def put(tube_name, payload, ttr: DEFAULT_TTR, pri: DEFAULT_PRI, delay: 0, con: nil, idp: nil)
        opts = {ttr: ttr, pri: pri, delay: delay}
        opts[:con] = con unless con.nil?
        opts[:idp] = idp unless idp.nil?
        with_producer do |conn|
          conn.tubes[tube_name].put(JSON.generate(payload), **opts)
        end
      end

      # Consumers WATCH tubes; producers USE them. Keeping the consumer on its
      # own connection avoids leaking watched-tube state into web threads.
      def consumer_client
        ::Beaneater.new(address)
      end

      # Pending jobs across the ingest pipeline. Used by the health endpoint
      # and the layout chrome to show backlog at a glance.
      INGEST_TUBES = [
        EVENTS_TUBE, TRANSACTIONS_TUBE, FORWARD_TUBE,
        MAINTENANCE_TUBE, ACTIVEJOB_TUBE
      ].freeze

      def queue_depth
        with_producer do |conn|
          INGEST_TUBES.sum do |name|
            conn.tubes[name].stats.current_jobs_ready.to_i
          rescue ::Beaneater::NotFoundError
            0
          end
        end
      rescue
        0
      end

      # Per-tube backlog for the settings page + MCP get_status. Fetched live —
      # tuber stats are in-memory, so there's nothing to gain from the 15-min
      # snapshot. A tube tuber hasn't created yet reports zeros; an unreachable
      # tuber yields {} rather than raising into the request path.
      def queue_depths
        with_producer do |conn|
          ALL_TUBES.to_h do |name|
            s = conn.tubes[name].stats
            [name, {ready: s.current_jobs_ready.to_i, reserved: s.current_jobs_reserved.to_i,
                    buried: s.current_jobs_buried.to_i, delayed: s.current_jobs_delayed.to_i}]
          rescue ::Beaneater::NotFoundError
            [name, {ready: 0, reserved: 0, buried: 0, delayed: 0}]
          end
        end
      rescue => e
        Rails.logger.warn("Ingest::Tuber.queue_depths failed: #{e.class}: #{e.message}")
        {}
      end
    end
  end
end

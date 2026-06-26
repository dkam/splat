# frozen_string_literal: true

module Ingest
  module Tuber
    EVENTS_TUBE = "splat.events"
    TRANSACTIONS_TUBE = "splat.transactions"
    LOGS_TUBE = "splat.logs"
    FORWARD_TUBE = "splat.forward"
    MAINTENANCE_TUBE = "splat.maintenance"
    ACTIVEJOB_TUBE = "splat.activejob"

    # TTR covers one full message round-trip (AR write into the cluster DB
    # plus any per-row work). With dictionary-compressed inserts and no
    # secondary cold-tier fan-out, processing is well under a second;
    # 120s leaves headroom before tuber re-releases the message.
    DEFAULT_TTR = 120
    DEFAULT_PRI = 1024

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

      # con: / idp: are tuber server extensions (per-key concurrency cap +
      # idempotency suppression). Tuber rejects unknown opts on vanilla
      # beanstalkd, so callers omit them unless they want the behavior.
      def put(tube_name, payload, ttr: DEFAULT_TTR, pri: DEFAULT_PRI, delay: 0, con: nil, idp: nil)
        opts = {ttr: ttr, pri: pri, delay: delay}
        opts[:con] = con unless con.nil?
        opts[:idp] = idp unless idp.nil?
        producer.tubes[tube_name].put(JSON.generate(payload), **opts)
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
        INGEST_TUBES.sum do |name|
          producer.tubes[name].stats.current_jobs_ready.to_i
        rescue ::Beaneater::NotFoundError
          0
        end
      rescue
        0
      end
    end
  end
end

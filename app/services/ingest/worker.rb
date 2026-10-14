# frozen_string_literal: true

module Ingest
  # Maps a worker role to the set of tube consumers it runs. Splitting roles
  # across processes keeps heavy background work (the splat.maintenance tube —
  # StorageStats scans, retention, dict training) off the latency-sensitive
  # ingest path: a slow or memory-hungry maintenance job in its own process
  # can't starve event/transaction/log ingestion the way it does when they
  # share one process.
  module Worker
    ROLES = {
      # Real-time ingestion: one consumer per data tube. SQLite serialises
      # writes per DB file, so one writer per DB is the useful ceiling; the
      # tubes write to separate DBs and so run concurrently.
      "ingest" => -> {
        [
          EventConsumer.new,
          TransactionConsumer.new,
          LogConsumer.new,
          CheckInConsumer.new,
          ForwardConsumer.new,
          ActiveJobConsumer.new,
          # Not a tube consumer: puts what the web spooled while tuber was
          # down back on the tubes above.
          SpoolReplayer.new
        ]
      },
      # Background/maintenance: drains splat.maintenance (the recurring jobs the
      # scheduler enqueues). Isolated so its heavy scans can't freeze ingest.
      "maintenance" => -> {
        [DispatchConsumer.new(tube: Tuber::MAINTENANCE_TUBE)]
      }
    }.freeze

    # bin/worker's arguments as a list of roles: "all", names given separately
    # or comma-separated, each once. Raises before anything starts on a name
    # that isn't a role.
    def self.roles_for(args)
      names = Array(args).flat_map { |a| a.to_s.split(/[\s,]+/) }.reject(&:empty?)
      names = ROLES.keys if names.include?("all")
      names.uniq.each { |name| check_role!(name) }
    end

    def self.consumers_for(role)
      check_role!(role)
      ROLES.fetch(role.to_s).call
    end

    def self.check_role!(role)
      ROLES.key?(role.to_s) or
        raise ArgumentError, "unknown worker role #{role.inspect} (expected one of: #{ROLES.keys.join(", ")}, or all)"
    end

    # Runs +consumers+ on a thread each until they stop, stopping them all on
    # TERM or INT. One role in this process; Ingest::Supervisor runs several.
    def self.run(name, consumers)
      shutdown = lambda do |signal|
        # warn (not Rails.logger) — Logger uses a mutex which can't be
        # acquired from a Ruby signal-trap context.
        warn "[Worker:#{name}] received #{signal}, draining and exiting"
        consumers.each(&:stop!)
      end
      trap("INT") { shutdown.call("SIGINT") }
      trap("TERM") { shutdown.call("SIGTERM") }

      Rails.logger.info "[Worker:#{name}] starting #{consumers.size} consumer(s)"
      consumers.map { |c| Thread.new { c.run } }.each(&:join)
    end
  end
end

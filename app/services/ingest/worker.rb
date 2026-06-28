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
          ForwardConsumer.new,
          ActiveJobConsumer.new
        ]
      },
      # Background/maintenance: drains splat.maintenance (the recurring jobs the
      # scheduler enqueues). Isolated so its heavy scans can't freeze ingest.
      "maintenance" => -> {
        [DispatchConsumer.new(tube: Tuber::MAINTENANCE_TUBE)]
      }
    }.freeze

    def self.consumers_for(role)
      builder = ROLES[role.to_s] or
        raise ArgumentError, "unknown worker role #{role.inspect} (expected one of: #{ROLES.keys.join(", ")})"
      builder.call
    end
  end
end

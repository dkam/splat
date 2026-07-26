# frozen_string_literal: true

# One-time seed of the facets table from existing logs/transactions.
#
# New rows populate facets at ingest (Facet.harvest! in the log/transaction
# consumers); this fills the distinct values already on disk so the filter
# dropdowns are complete the moment the read path switches to Facet.values_for.
# Idempotent — a second run just re-bumps last_seen_at.
#
# These DISTINCT scans are exactly what the facets table exists to avoid, run
# once offline. On a busy logs table they take a while; that cost is paid once.
# last_seen_at is set to now: every surviving row was seen within its retention
# window, so a truly-dead value simply ages out on the next prune.
namespace :splat do
  desc "Backfill the facets table from existing logs and transactions"
  task backfill_facets: :environment do
    now = Time.current

    seed = lambda do |stream, name, pairs|
      rows = pairs.filter_map do |project_id, value|
        next if project_id.blank? || value.blank?

        {project_id: project_id, stream: stream, name: name, value: value.to_s,
         last_seen_at: now, created_at: now, updated_at: now}
      end
      next 0 if rows.empty?

      Facet.upsert_all(
        rows,
        unique_by: :index_facets_on_scope_and_value,
        on_duplicate: Arel.sql("last_seen_at = excluded.last_seen_at")
      )
      rows.size
    end

    %w[environment source service release].each do |name|
      count = seed.call("log", name, Log.distinct.pluck(:project_id, name.to_sym))
      puts "  logs.#{name}: #{count} values"
    end

    count = seed.call("transaction", "environment", Transaction.distinct.pluck(:project_id, :environment))
    puts "  transactions.environment: #{count} values"

    puts "Done. facets now holds #{Facet.count} rows."
  end
end

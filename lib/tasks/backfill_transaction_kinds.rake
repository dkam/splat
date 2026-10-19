# frozen_string_literal: true

# One-time seed of the transaction kind lookup (TransactionKind) from existing
# transactions.
#
# New transactions classify their name at ingest; this classifies the names
# already on disk, so the performance page's Jobs filter isn't missing every job
# that hasn't run since the upgrade. Idempotent — a second run recomputes the
# same names and keeps the later last_seen_at.
#
# It groups each project's transactions by (name, op), which reads every row:
# op has no index, and this is the scan the lookup exists to avoid, paid once.
# Names whose raw rows have already aged out can't be classified; their rollups
# read as web requests.
namespace :splat do
  desc "Backfill the transaction kind lookup (job and other names) from existing transactions"
  task backfill_transaction_kinds: :environment do
    now = Time.current
    total = 0

    Project.find_each do |project|
      # MAX(timestamp), not the backfill time: last_seen_at is the prune clock.
      rows = Transaction.where(project_id: project.id)
        .group(:transaction_name, :op).maximum(:timestamp)
        .filter_map do |(name, op), last_seen_at|
          kind = TransactionKind.classify(op)
          next if kind == "web" || name.blank?

          {project_id: project.id, stream: TransactionKind::STREAM, name: kind, value: name,
           last_seen_at: last_seen_at, created_at: now, updated_at: now}
        end
      # A name with several non-web ops would repeat its (kind, name) key, which
      # one upsert statement can't take twice.
      rows = rows.group_by { |r| [r[:name], r[:value]] }.map { |_, dupes| dupes.max_by { |r| r[:last_seen_at] } }
      next if rows.empty?

      rows.each_slice(500) do |slice|
        Facet.upsert_all(
          slice,
          unique_by: :index_facets_on_scope_and_value,
          on_duplicate: Arel.sql("last_seen_at = MAX(last_seen_at, excluded.last_seen_at)")
        )
      end
      total += rows.size
      puts "  #{project.slug}: #{rows.count { |r| r[:name] == "job" }} jobs, #{rows.count { |r| r[:name] == "other" }} other"
    end

    puts "Done. #{total} names classified."
  end
end

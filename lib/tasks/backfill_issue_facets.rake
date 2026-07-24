# frozen_string_literal: true

# One-time seed of issue_facets from existing events.
#
# New rows populate it at ingest (IssueFacet.harvest! in
# Event.create_from_sentry_payload!); this fills the (issue, environment) and
# (issue, release) pairs already on disk so the issue filters aren't blind to
# everything ingested before the upgrade. Idempotent — a second run recomputes
# the same pairs and leaves last_seen_at at the later of the two values.
#
# The GROUP BY over events is exactly what issue_facets exists to avoid, run
# once offline. It's batched by issue_id so a large events table doesn't build
# one enormous result set. Issues whose events have aged out of retention get
# no facets and so match no environment filter — correct, since we no longer
# have evidence of where they were seen.
namespace :splat do
  desc "Backfill issue_facets (issue -> environment/release) from existing events"
  task backfill_issue_facets: :environment do
    now = Time.current
    total = 0

    Issue.in_batches(of: 500) do |issues|
      # One aggregate per facet name, rather than one query over both columns:
      # grouping by (issue, environment, release) together would repeat an
      # issue's environment once per release it was seen in.
      #
      # MAX(timestamp), not the backfill time: last_seen_at is the retention
      # clock, and retire_issue_facets drops a pair once every event carrying it
      # has aged out. Stamping `now` would give an issue whose only staging
      # event is 89 days old a fresh 90-day lease on matching `staging`.
      rows = IssueFacet::NAMES.flat_map do |name|
        Event.where(issue_id: issues.select(:id))
          .where.not(name => [nil, ""])
          .group(:project_id, :issue_id, name)
          .maximum(:timestamp)
          .map do |(project_id, issue_id, value), last_seen_at|
            {
              project_id: project_id, issue_id: issue_id, name: name, value: value.to_s,
              last_seen_at: last_seen_at, created_at: now, updated_at: now
            }
          end
      end
      next if rows.empty?

      # MAX, as in IssueFacet.harvest! — a backfill run after ingest has already
      # recorded a pair must not drag its last_seen_at back to the newest event
      # still on disk.
      IssueFacet.upsert_all(
        rows,
        unique_by: :index_issue_facets_on_issue_and_value,
        on_duplicate: Arel.sql("last_seen_at = MAX(issue_facets.last_seen_at, excluded.last_seen_at)")
      )
      total += rows.size
      print "."
    end

    puts
    puts "Done. Seeded #{total} pairs; issue_facets now holds #{IssueFacet.count} rows."
  end
end

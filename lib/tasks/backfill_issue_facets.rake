# frozen_string_literal: true

# One-time seed of issue_facets from existing events.
#
# New rows populate it at ingest (IssueFacet.harvest! in
# Event.create_from_sentry_payload!); this fills the (issue, environment) and
# (issue, release) pairs already on disk so the issue filters aren't blind to
# everything ingested before the upgrade. Idempotent — a second run just
# re-bumps last_seen_at.
#
# The DISTINCT over events is exactly what issue_facets exists to avoid, run
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
      # One DISTINCT per facet name, rather than one over both columns at once:
      # a combined DISTINCT is over (issue, environment, release), so an issue
      # seen across N releases repeats its environment N times and the result
      # needs de-duplicating in Ruby afterwards. Per-name, the DB returns each
      # pair exactly once.
      rows = IssueFacet::NAMES.flat_map do |name|
        Event.where(issue_id: issues.select(:id))
          .where.not(name => [nil, ""])
          .distinct
          .pluck(:project_id, :issue_id, name)
          .filter_map do |project_id, issue_id, value|
            next if project_id.blank?

            {
              project_id: project_id, issue_id: issue_id, name: name, value: value.to_s,
              last_seen_at: now, created_at: now, updated_at: now
            }
          end
      end
      next if rows.empty?

      IssueFacet.upsert_all(
        rows,
        unique_by: :index_issue_facets_on_issue_and_value,
        on_duplicate: Arel.sql("last_seen_at = excluded.last_seen_at")
      )
      total += rows.size
      print "."
    end

    puts
    puts "Done. Seeded #{total} pairs; issue_facets now holds #{IssueFacet.count} rows."
  end
end

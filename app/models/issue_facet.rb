# frozen_string_literal: true

# Ingest-maintained (issue, name, value) pairs — currently environment and
# release — that make "issues seen in staging" an indexed lookup instead of a
# DISTINCT over events.
#
# Sibling of Facet, with one deliberate difference: Facet lives on primary and
# only ever feeds options_for_select, so it never joins. This one is joined
# (the filter is a subquery against it), so it lives on the issues_events DB
# beside the issues it points at.
class IssueFacet < IssuesEventsRecord
  # An error burst is the exact case this protects — thousands of events, one
  # issue, one environment, one write.
  include HarvestThrottle

  belongs_to :issue

  # Names we harvest. Kept explicit so a typo'd key is a no-op rather than a new
  # facet name quietly accumulating rows. Note these double as literal Event
  # column names in lib/tasks/backfill_issue_facets.rake — adding a facet that
  # isn't a column there needs that task taught how to source it.
  NAMES = %w[environment release].freeze

  class << self
    # Read path: distinct values for the filter dropdown, scoped to a project.
    def values_for(project_id, name)
      where(project_id: project_id, name: name.to_s)
        .distinct.order(:value).pluck(:value)
    end

    # Read path: {issue_id => [value, ...]} for a page of issues, so the row
    # chips don't fire a query per row.
    def values_by_issue(issue_ids, name)
      return {} if issue_ids.empty?

      where(issue_id: issue_ids, name: name.to_s)
        .order(:value)
        .pluck(:issue_id, :value)
        .each_with_object({}) { |(issue_id, value), h| (h[issue_id] ||= []) << value }
    end

    # Issue ids seen with this value — used as a subquery, not materialised.
    # project_id is optional: the web UI is always project-scoped, MCP is
    # instance-wide unless the caller narrows it. There's an index for each.
    def issue_ids_for(name, value, project_id: nil)
      scope = where(name: name.to_s, value: value.to_s)
      scope = scope.where(project_id: project_id) if project_id
      scope.select(:issue_id)
    end

    # Ingest path. `values` maps facet name => value, e.g.
    # {environment: "production", release: "v1.2.3"}. Blanks are skipped, each
    # distinct pair is throttled by REFRESH_INTERVAL, and survivors are upserted
    # in one statement (ON CONFLICT bumps last_seen_at).
    def harvest!(project_id:, issue_id:, values:, seen_at: Time.current)
      # The throttle runs on wall time, never seen_at: seen_at is the event's
      # timestamp (client-supplied, unvalidated), and a future-dated one would
      # otherwise poison the prune clock and disable eviction for the life of
      # the process. seen_at is only the row's retention value, below.
      now = Time.current
      rows = []
      values.each do |name, value|
        name = name.to_s
        next unless NAMES.include?(name)
        next if value.blank?
        next unless due?("#{issue_id}\t#{name}\t#{value}", now)

        rows << {
          project_id: project_id, issue_id: issue_id, name: name, value: value.to_s,
          last_seen_at: seen_at, created_at: seen_at, updated_at: seen_at
        }
      end
      return if rows.empty?

      # MAX, not a straight assignment: seen_at is the *event's* timestamp, and
      # events arrive out of order. Assigning would let a late-delivered old
      # event drag last_seen_at backwards and retire a live value early.
      upsert_all(
        rows,
        unique_by: :index_issue_facets_on_issue_and_value,
        on_duplicate: Arel.sql("last_seen_at = MAX(issue_facets.last_seen_at, excluded.last_seen_at)")
      )
    end
  end
end

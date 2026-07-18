# frozen_string_literal: true

# Normalized, ingest-maintained distinct values for the filter dropdowns
# (logs: environment/source/service; transactions: environment). Replaces the
# per-request DISTINCT scans over the high-volume logs/transactions tables — a
# DISTINCT there walks every index entry (SQLite has no loose index scan) and
# costs tens of seconds at ~1M rows; reading a value here is a covered lookup.
#
# Never joined to logs/transactions (it only feeds options_for_select), so it
# lives on the primary DB beside projects with no cross-DB join. Ingest already
# resolves the Project from primary, so maintaining it adds no new DB touch.
class Facet < ApplicationRecord
  belongs_to :project

  # Cap how often a given (project, stream, name, value) is re-upserted per
  # process. The upsert only bumps last_seen_at (the prune clock), so one write
  # per value per interval is plenty — without it, every high-volume log batch
  # would re-upsert the same handful of values.
  REFRESH_INTERVAL = 10.minutes

  @recent = {}
  @mutex = Mutex.new

  class << self
    # Read path: the sorted distinct values for one facet. Covered by
    # index_facets_on_scope.
    def values_for(project_id, stream, name)
      where(project_id: project_id, stream: stream.to_s, name: name.to_s)
        .order(:value).pluck(:value)
    end

    # Ingest path. `values` maps facet name => a value or array of values, e.g.
    # {environment: "production", source: %w[otlp sentry]}. Blanks are skipped,
    # each distinct value is throttled by REFRESH_INTERVAL, and the survivors are
    # upserted in one statement (ON CONFLICT bumps last_seen_at).
    def harvest!(project_id:, stream:, values:, seen_at: Time.current)
      stream = stream.to_s
      rows = []
      values.each do |name, vals|
        name = name.to_s
        Array(vals).uniq.each do |value|
          next if value.blank?
          next unless due?(project_id, stream, name, value.to_s, seen_at)

          rows << {
            project_id: project_id, stream: stream, name: name, value: value.to_s,
            last_seen_at: seen_at, created_at: seen_at, updated_at: seen_at
          }
        end
      end
      return if rows.empty?

      upsert_all(
        rows,
        unique_by: :index_facets_on_scope_and_value,
        on_duplicate: Arel.sql("last_seen_at = excluded.last_seen_at")
      )
    end

    private

    # True at most once per REFRESH_INTERVAL for a given value; records the
    # sighting time so the next call within the window is skipped. Idempotent
    # under racing workers anyway — the upsert's unique index absorbs dupes.
    def due?(project_id, stream, name, value, now)
      key = "#{project_id}\t#{stream}\t#{name}\t#{value}"
      @mutex.synchronize do
        last = @recent[key]
        return false if last && now - last < REFRESH_INTERVAL

        @recent[key] = now
        true
      end
    end
  end
end

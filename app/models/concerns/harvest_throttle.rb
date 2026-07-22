# frozen_string_literal: true

# Shared write-throttle for the ingest-maintained facet tables (Facet on
# primary, IssueFacet on issues_events). Both upsert rows whose only mutable
# column is last_seen_at, so re-writing the same key more than once per
# interval buys nothing — and on the ingest path "the same key" is the common
# case: one high-volume log batch, or an error burst hammering one issue, is
# thousands of events carrying a handful of distinct values.
#
# Each including class gets its own memo; only the key composition differs, so
# `due?` takes a prebuilt key string.
module HarvestThrottle
  extend ActiveSupport::Concern

  # How often a given key may be re-upserted per process.
  REFRESH_INTERVAL = 10.minutes

  included do
    @recent = {}
    @mutex = Mutex.new
  end

  class_methods do
    # Test seam: the memo is process-global, so a test harvesting the same key
    # twice would otherwise silently get one write.
    def reset_throttle!
      @mutex.synchronize do
        @recent.clear
        @pruned_at = nil
      end
    end

    private

    # True at most once per REFRESH_INTERVAL for a given key; records the
    # sighting time so the next call within the window is skipped. Idempotent
    # under racing workers anyway — the upsert's unique index absorbs dupes.
    def due?(key, now)
      @mutex.synchronize do
        prune_expired(now)
        last = @recent[key]
        return false if last && now - last < REFRESH_INTERVAL

        @recent[key] = now
        true
      end
    end

    # An entry older than REFRESH_INTERVAL can never suppress a write again, so
    # keeping it is pure leak. That matters most for IssueFacet, whose key
    # includes issue_id and so grows with issue count × releases rather than
    # being the small closed set Facet's keys form — workers run for weeks.
    # Sweeping at most once per interval keeps this O(n) per interval rather
    # than per call, and leaves the memo proportional to live traffic.
    def prune_expired(now)
      return if @pruned_at && now - @pruned_at < REFRESH_INTERVAL

      @recent.delete_if { |_, last| now - last >= REFRESH_INTERVAL }
      @pruned_at = now
    end
  end
end

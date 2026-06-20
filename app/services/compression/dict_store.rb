require "concurrent/map"
require "zstd-ruby"

module Compression
  # Per-process cache of zstd dictionaries.
  #
  # Indexed by (db, id) for direct lookups (encode-known and decode-by-row-id).
  # Also tracks the currently-active dict id for each (db, segment) so the
  # chooser can ask "what dict do I write events:project:42 with right now?".
  #
  # Entries hold raw bytes plus pre-constructed Zstd::CDict/DDict, since
  # constructing those is cheap-ish but not free per-call.
  class DictStore
    Entry = Struct.new(:id, :segment, :version, :bytes, :cdict, :ddict)

    # How long an active-id lookup is cached before it's re-read from the DB.
    # Bounds how long a worker keeps writing with a stale answer after another
    # process promotes a dict — most importantly, a worker that started before
    # the first dict was seeded caches the "no active dict" result (which would
    # otherwise stick until restart, forcing plain-zstd rows forever) for only
    # this long before picking the new dict up.
    ACTIVE_TTL = 60 # seconds

    class << self
      def fetch(db, id)
        return nil if id.nil?
        by_id(db)[id] ||= load_row(db, id)
      end

      # Active dict id for a segment (e.g. "events" or "events:platform:python").
      # Returns nil if no active dict exists for that segment. Cached per process
      # with a short TTL so cross-process promotions are picked up without a
      # restart (in-process promotion calls invalidate_active for an instant swap).
      def active_id(db, segment)
        cache = active_by_segment(db)
        entry = cache[segment]
        if entry.nil? || entry[:expires_at] <= monotonic_now
          value = model(db).where(segment: segment, active: true).order(version: :desc).limit(1).pick(:id) || :missing
          entry = { value: value, expires_at: monotonic_now + ACTIVE_TTL }
          cache[segment] = entry
        end
        entry[:value] == :missing ? nil : entry[:value]
      end

      # Invalidate the active-id cache for a segment. Called after the
      # training job promotes a new dict so the next write picks it up.
      def invalidate_active(db, segment)
        active_by_segment(db).delete(segment)
      end

      # Wipe everything — useful in tests.
      def reset!
        @by_id = {}
        @active_by_segment = {}
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def model(db)
        case db
        when :issues_events then IssuesEventsDict
        else raise ArgumentError, "unknown db #{db.inspect} — compression is events-only"
        end
      end

      def by_id(db)
        (@by_id ||= {})[db] ||= Concurrent::Map.new
      end

      def active_by_segment(db)
        (@active_by_segment ||= {})[db] ||= Concurrent::Map.new
      end

      def load_row(db, id)
        row = model(db).find_by(id: id)
        return nil unless row
        Entry.new(row.id, row.segment, row.version, row.dict,
                  Zstd::CDict.new(row.dict), Zstd::DDict.new(row.dict))
      end
    end
  end
end

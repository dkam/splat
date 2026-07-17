# frozen_string_literal: true

# One-time backfill of events.trace_id from the compressed payload.
#
# New events populate trace_id at ingest (Event.create_from_sentry_payload!);
# this fills rows written before that shipped. Optional — without it, coverage
# fills in on its own as the 30-day events retention turns over. Worth running
# if you want error<->transaction correlation on existing data today.
#
# Unlike the transactions backfill this can't be done in SQL: the trace_id lives
# inside the zstd payload blob, so every row has to be decoded in Ruby. That's
# the whole cost (~334k decodes on production, a few minutes). Only rows with a
# NULL trace_id are read, so a second run is nearly free.
#
# Walks the id range in batches rather than `WHERE trace_id IS NULL LIMIT n` —
# events whose payload carries no trace stay NULL forever and would make that
# form loop until the heat death of the universe.
namespace :splat do
  desc "Backfill events.trace_id from the payload's contexts.trace.trace_id"
  task backfill_event_trace_id: :environment do
    batch_size = Integer(ENV.fetch("BATCH", "1000"))
    max_id = Event.maximum(:id) || 0
    filled = 0
    scanned = 0
    failed = 0
    start = 0

    while start <= max_id
      finish = start + batch_size
      # Select only what the decode needs — the payload blob is the point, and
      # skipping the wide text columns keeps each batch small.
      batch = Event.where(trace_id: nil)
        .where("id > ? AND id <= ?", start, finish)
        .select(:id, :payload_blob, :dict_id)

      pairs = batch.filter_map do |event|
        scanned += 1
        trace_id = event.payload&.dig("contexts", "trace", "trace_id")
        [event.id, trace_id] if trace_id.present?
      rescue => e
        # A corrupt or undecodable blob shouldn't abort the whole run.
        failed += 1
        warn "  skipped event #{event.id}: #{e.class}: #{e.message}"
        nil
      end

      # One transaction per batch: SQLite fsyncs once instead of per row.
      IssuesEventsRecord.transaction do
        pairs.each do |id, trace_id|
          Event.where(id: id).update_all(trace_id: trace_id)
          filled += 1
        end
      end

      puts "  scanned ids #{start}..#{finish} — #{scanned} read, #{filled} filled" if (finish % (batch_size * 20)).zero?
      start = finish
      sleep 0.05
    end

    puts "Done. Backfilled trace_id on #{filled} of #{scanned} events read#{" (#{failed} undecodable)" if failed > 0}."
  end
end

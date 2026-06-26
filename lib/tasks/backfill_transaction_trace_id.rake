# frozen_string_literal: true

# One-time backfill of transactions.trace_id from the legacy spans table.
#
# New transactions populate trace_id at ingest (Transaction.create_from_sentry_payload!);
# this fills pre-existing rows so log↔transaction correlation can move off the
# per-span trace_id index — which migration 20260625000003 drops. Run this AFTER
# the trace_id write path is deployed and BEFORE that migration.
#
# Re-runnable: only touches rows where trace_id IS NULL. Walks the id range in
# batches (rather than `WHERE trace_id IS NULL LIMIT n`, which would loop forever
# on transactions that have no spans and so stay NULL).
namespace :splat do
  desc "Backfill transactions.trace_id from spans (run before dropping the per-span trace index)"
  task backfill_transaction_trace_id: :environment do
    batch_size = Integer(ENV.fetch("BATCH", "5000"))
    conn = TransactionsSpansRecord.connection
    max_id = Transaction.maximum(:id) || 0
    filled = 0
    start = 0

    while start <= max_id
      finish = start + batch_size
      filled += conn.exec_update(<<~SQL.squish)
        UPDATE transactions
           SET trace_id = (
             SELECT s.trace_id FROM spans s
              WHERE s.project_id = transactions.project_id
                AND s.transaction_id = transactions.transaction_id
              LIMIT 1
           )
         WHERE trace_id IS NULL
           AND id > #{start} AND id <= #{finish}
           AND EXISTS (
             SELECT 1 FROM spans s
              WHERE s.project_id = transactions.project_id
                AND s.transaction_id = transactions.transaction_id
           )
      SQL
      puts "  scanned ids #{start}..#{finish}, filled #{filled} so far" if (finish % (batch_size * 20)).zero?
      start = finish
      sleep 0.05
    end

    puts "Done. Backfilled trace_id on #{filled} transactions."
  end
end

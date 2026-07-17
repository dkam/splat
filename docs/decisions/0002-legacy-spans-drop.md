# 0002 — Drop the legacy `spans` table once it ages out, and don't VACUUM afterwards

**Date:** 2026-07-17
**Status:** Accepted — action pending ~2026-07-28
**Affects:** `Span`, `Span::Node`, `Maintenance::RetentionJob`, `TransactionsController`,
`Mcp::McpController`, `StorageStats`, `transactions_spans` schema

## Context

v1.7.0 (2026-06-28) replaced per-span rows with one zstd-compressed blob per
transaction tree (`span_trees`), reading through a dual-read fallback and with no
backfill. The `spans` table has been frozen since: `Ingest::TransactionConsumer`
contains no `Span` writes at all, only `SpanTree` ones. `retention_job.rb:64`
recorded the intent to drop it "after the blob cutover's transactions have fully
aged out (~30 days)".

A `dbstat` breakdown of `production_transactions_spans.sqlite3` (91.8GB) on
2026-07-17 shows how much that frozen table is costing:

| Object | Size | Share of file |
|---|---:|---:|
| `transactions` table | 43.1 GB | 47% |
| **`spans` table** | **24.8 GB** | **27%** |
| `span_trees` table | 13.6 GB | 15% |
| **`spans` indexes (×3)** | **8.2 GB** | **9%** |
| `transactions` indexes (×7) | 1.4 GB | 2% |
| everything else | ~0.6 GB | <1% |

`spans` plus its three indexes is **33.1 GB — 36% of this file and 28% of all
~116GB of Splat storage**. The 8.2GB of indexes are maintained for a table
nothing writes to and only the dual-read fallback reads from.

`spans_data_retention_days` is 30 and the last row was written 2026-06-28, so
retention removes roughly one day of it per day. It held ~11 days of data on
2026-07-17 and **empties around 2026-07-28**.

## Decision

**1. Drop the table once retention empties it (~2026-07-28), not before.** The
dual-read fallback is what makes pre-cutover transactions still viewable; pulling
it early silently blanks spans for any transaction older than the cutover.
Confirm empty first — `SELECT MAX(timestamp) FROM spans` — rather than trusting
the date arithmetic.

**2. Do not `VACUUM` afterwards.** Dropping the table frees ~33GB of pages, but
SQLite never returns them to the OS without a full rewrite (see
`docs/learnings/sqlite.md`). At the observed ~3.2 GB/day growth, the freelist
absorbs **~10 days of growth for free** and the file simply stops growing. A
92GB `VACUUM` costs hours under an exclusive lock and needs ~92GB of temp space,
and buys only disk we don't need — `/storage` had 1.1TB free at the time of
writing. Revisit only if the disk gets tight.

## Alternatives considered

**Drop `spans` immediately and backfill `span_trees` from it.** Rejected at
v1.7.0 and still rejected: a backfill re-reads and re-compresses 25GB to save
~11 days of waiting for retention to do it for free.

**Keep the table indefinitely — it's aging out anyway.** Rejected: retention
empties the *rows*, but the table and its three indexes remain in the schema, and
the dual-read fallback stays on every span lookup forever. The 33GB is reclaimed
either way; the point of the drop is removing dead code and dead indexes.

**VACUUM to reclaim the 33GB.** Rejected — see above. This is the tempting one,
because "33GB freed" reads like it should show up in `df`. It won't, and chasing
it costs an outage.

## Checklist

Ordered; each step is independently revertible.

1. **Confirm empty:** `SELECT COUNT(*) FROM spans` returns 0 (or
   `MAX(timestamp)` is older than the span cutoff). Do not proceed on the date
   alone.
2. **Remove the read fallback** in `Span.for_transaction` (`app/models/span.rb`)
   — the `else` branch that maps `Span::Node.from_record` over `spans` rows.
   Once `spans` is empty this branch returns `[]`, so removing it is behaviour-
   preserving.
3. **Remove `Span::Node.from_record`** (`app/models/span/node.rb`) — dead once
   step 2 lands. `from_tree` stays; it's the live path.
4. **Remove the `Span` pruning branches** in
   `Maintenance::RetentionJob#retire_transactions_and_spans` (the
   `batched_delete_all(Span.where(...))` and the per-batch
   `Span.where(project_id:, transaction_id:)` delete).
5. **Update the callers** that go through `Span.for_transaction` —
   `TransactionsController#show` and `Mcp::McpController`. They can read
   `SpanTree` directly once the fallback is gone.
6. **Drop the `StorageStats.counts` legacy term** — `rows["spans"].to_i +` in
   `counts`. The `spans` key disappears from the deep pass's `groups` once the
   table is gone, so the term becomes a permanent zero.
7. **Migration:** drop the `spans` table (its three indexes go with it).
8. **Do not VACUUM.** Expect `PRAGMA page_count` to keep reporting ~92GB while
   the `dbstat` totals fall by ~33GB. That divergence is correct, not a bug.

### Watch out: `Span::Node` lives inside the `Span` namespace

The AR model `Span` is what we're retiring, but `Span::Node` is the live
representation used by `from_tree` and must survive. Deleting `app/models/span.rb`
outright would orphan `Span::Node` under Zeitwerk. Either keep `Span` as a bare
namespace module, or rehome the node (e.g. `SpanTree::Node`) and update callers.
This is a decision the drop has to make explicitly — don't discover it at
migration time.

## Consequences

- ~33GB of the file becomes free pages, absorbing ~10 days of growth. The
  headline "SQLite total" on the settings page will look *flat* rather than
  falling — correct, and worth explaining in the UI, since the `dbstat` group
  subtotals will drop by 33GB at the same moment. Storage growth tracking should
  record both series for exactly this reason.
- Span lookups lose a branch and a `SpanTree.find_by` miss no longer falls back
  to a table scan of a dead table.
- Pre-cutover transactions (before 2026-06-28) will have aged out of the 90-day
  transaction retention by ~2026-09-26 regardless, so no user-visible span data
  is lost by the drop — the rows it would have served are already gone.

## Not in scope

`transactions` is the real target after this: at 43.1GB it's 47% of the file, the
single largest object, and it isn't in `StorageStats::COMPRESSED` — so the
settings page can't even show its ratio. It has a `measurements_blob`, but
`measurements` and `tags` are still raw JSON columns alongside per-row repeated
strings (`transaction_name`, `http_url`, `server_name`, `release`). `events` and
`logs` get ~6× from dictionary compression on similar data. Worth measuring
before promising a number.

## See also

- `docs/learnings/sqlite.md` — why `DELETE`/`DROP` don't shrink the file.
- `docs/decisions/0001-storage-stats-cadence.md` — the scan that surfaced this.

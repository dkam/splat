# 0003 — Maintain filter-dropdown facets at ingest, not by DISTINCT on read

**Date:** 2026-07-18
**Status:** Accepted — shipped v1.8.0
**Affects:** `Facet` (new), `Ingest::LogConsumer`, `Ingest::TransactionConsumer`,
`LogsController`, `EndpointsController`, `Maintenance::RetentionJob`, primary schema

## Context

The logs page took ~100s to load for a busy project. A span waterfall
(transaction #293746, 2026-07-17) showed the entire wall-clock was three
`SELECT DISTINCT` scans over the ~1M-row `logs` table, run to populate the
environment/source/service filter dropdowns: **source 55.8s, service 35.2s,
environment 9.7s**. The endpoints page had the same shape at smaller scale — one
`DISTINCT` over `transactions` for its environment dropdown (~4s P95).

The queries were wrapped in a `Rails.cache.fetch` with a 5-minute TTL, so the
cost wasn't paid every request — but every visitor arriving after the TTL lapsed
paid the full ~100s, which is exactly the usage pattern (a human checking logs a
few times a day). The cache moved the pain around; it didn't remove it.

The root cause is structural, not a missing index: **SQLite has no loose index
scan**, so a `DISTINCT` reads every entry in the scanned range regardless of
indexing. The `environment` column was already covered by
`index_logs_on_project_id_and_environment` and *still* took 9.7s. See
`docs/learnings/sqlite.md` — "`DISTINCT`/`GROUP BY` have no loose index scan".

## Decision

Maintain the distinct facet values in a small normalized `facets` table,
populated **at ingest**, and read that on the request path. The dropdown queries
become covered lookups over a table with tens of rows instead of `DISTINCT`
scans over millions.

**On the primary DB, one unified table.** Columns `(project_id, stream, name,
value, last_seen_at)`, unique on `(project_id, stream, name, value)`. `stream`
(`"log"` / `"transaction"`) keeps `log.environment` distinct from
`transaction.environment`, so both slow pages are fixed by one mechanism.

- **Primary, not the segment DBs.** Facets are never joined to logs/transactions
  — they only feed `options_for_select`. The cross-DB-join rule that keeps
  `Log`/`Transaction` off primary therefore doesn't apply, and ingest already
  resolves the `Project` from primary (`project_for`), so maintaining facets adds
  no new DB touch. It also makes `Project has_many :facets` a real association.
- **Throttled upsert.** `Facet.harvest!` filters blanks, dedupes the batch, and
  upserts (`ON CONFLICT DO UPDATE last_seen_at`), but a process-local memo caps
  re-writes to one per value per `REFRESH_INTERVAL` (10 min). Without it every
  high-volume log batch would re-upsert the same handful of values. Mirrors
  `Release.record_sighting!`.
- **Best-effort.** A harvest failure logs and is swallowed — it must never fail
  (and retry) the ingest, because facets are cosmetic. The prune and later
  batches self-heal a miss.
- **Pruned by retention.** `RetentionJob` drops facet rows whose `last_seen_at`
  is past the matching stream's data-retention window (logs 14d, transactions
  90d), so a value that stops arriving leaves the dropdown.
- **One-time backfill.** `splat:backfill_facets` seeds the table from existing
  rows (the very DISTINCT scans, run once offline).

## Alternatives considered

**Index the facet columns.** Rejected — this is the intuitive fix and it does not
work. `environment` was already covered and still took 9.7s; SQLite walks every
index entry for a `DISTINCT` (no skip scan). An index removes the temp b-tree,
not the O(rows) walk.

**Just raise the cache TTL.** Rejected — a longer TTL widens the window but the
first visitor after each expiry still eats the full scan, and the data is exactly
the kind you want current (a new environment should show up promptly). It also
kept per-facet `solid_cache` read/write churn on every page load. Dropping the
`DISTINCT` lets us drop the cache entirely.

**Trigger-maintained count table on the logs DB.** Rejected — the facets need to
live where they're read cheaply, and a SQLite trigger can't write across DB files
to primary. Keeping facets on the logs DB to suit a trigger would then force a
cross-DB story on the read side for no gain. Ingest-side harvest is simpler and
already has the values in memory.

**Per-segment facet tables (one on each DB).** Considered — the values do
originate on their own segments. Rejected in favour of one primary table: facets
are tiny and never joined, so co-locating them with their source table buys
nothing, and a single table means a single model, one read path, and one prune.

## Consequences

- Both dropdowns become sub-millisecond covered lookups; the logs page is no
  longer dominated by facet queries.
- Ingest does a little more work — a throttled upsert per batch/transaction — but
  it's bounded to one write per distinct value per 10 min per process.
- **Deploy is two-step:** run the migration and `splat:backfill_facets` before
  the read path switches to `Facet.values_for`, so the dropdowns are never empty.
  The view guards (`if @services.size > 1`) make a single combined deploy merely
  *sparse* briefly rather than broken, but the ordered path guarantees no
  regression.
- A facet can lag reality by up to `REFRESH_INTERVAL` + a prune cycle. For an
  `<option>` list that's fine; it was the explicit trade in choosing best-effort
  over transactional consistency (the upsert can't share the log/transaction
  insert's transaction — different DBs).

## See also

- `docs/learnings/sqlite.md` — no loose index scan; why the index didn't help.
- `docs/decisions/0001-storage-stats-cadence.md` — the other "don't do the
  expensive scan on a hot path" decision.

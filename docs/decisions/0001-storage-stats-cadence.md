# 0001 — Split the storage stats scan into a cheap hourly pass and a deep daily one

**Date:** 2026-07-17
**Status:** Accepted
**Affects:** `StorageStats`, `Maintenance::StorageStatsJob`, `config/schedule.yml`

## Context

`Maintenance::StorageStatsJob` computed the settings page's storage snapshot on
a `*/15` cron. It was written when the DBs were small. By 2026-07 they were
~120GB (92GB of that `production_transactions_spans.sqlite3`) and a single pass
took **75–80 minutes and was lengthening daily** — 4430s at 10:44, 4805s at
21:35 on the same day.

Three separate full-dataset reads per pass:

1. `dbstat` page walk for per-table byte sizes — O(file size).
2. `COUNT(*)` per table — SQLite has no row-count metadata.
3. `ORDER BY RANDOM() LIMIT 500` on `events`, `logs`, `span_trees` to sample
   blobs for the compression ratio — a full scan *plus* a spill-to-disk sort of
   a 92GB table.

Consequences, all of which had gone unnoticed:

- The maintenance worker **never idled**. `docker stats` showed 23.5TB of block
  reads and 148GB of writes (sorter spill) on that container.
- Three jobs sat permanently ready on `splat.maintenance` (`oldest_ready_age`
  ~3500s, `queue_time_ewma` 1543s). The `idp:` key did not prevent this — it
  only suppresses puts while a job is *queued*, not while it runs.
- The consumer is single-threaded, so `HistogramRollupJob` and the OIDC cleanup
  were starved behind it, firing in the 2-second gaps between passes. Rollups
  ran ~75 minutes apart instead of hourly.
- None of it was visible in splat-splat: the tuber consumers open no Sentry
  transaction, so the worst path in the system emitted no telemetry. It was
  found by reading `docker stats` by hand.

## Decision

Split by cost:

- **`refresh!` — hourly.** Index seeks and pragmas only: `PRAGMA page_count` for
  the headline total, anchored-rowid sampling for compression ratios, split
  MIN/MAX seeks for retention bounds. Carries `groups`/`counts` forward from the
  last deep pass; `deep_collected_at` records their age for the view.
- **`refresh_deep!` — daily, 03:40.** Adds the `dbstat` walk and the per-table
  `COUNT(*)`s. Also the cold-cache path, since `refresh!` never builds `groups`
  itself.

Measured: the hourly pass runs in **0.03s**, every query planning as `SEARCH`.

Two supporting changes fell out:

- `Ingest::Scheduler` gained `args:` support (it hardcoded `args: []`, so the
  deep entry would have silently run as a fast pass — caught only by checking
  the plumbing end to end).
- `data_span` had the same `MIN(x), MAX(x)` full-scan bug, with a comment
  claiming the opposite. Fixed; it's on the hourly path now.

## Verification

Plans and timings confirmed against the live production DBs (read-only,
2026-07-17), not just dev — dev's DBs are small enough that a bad plan is
invisible there:

| Query | Prod plan | Prod time |
|---|---|---|
| Anchored sample, 25 × 20 rows on `span_trees` (92GB) | `SEARCH … INTEGER PRIMARY KEY (rowid>?)` | 0.304s |
| `MIN(id)` / `MAX(id)` split, `span_trees` | `SEARCH span_trees` | instant |
| `MIN(ts), MAX(ts)` combined, `logs` (24GB) — **old form** | `SCAN … USING COVERING INDEX` | **28.517s** |
| `MIN(ts)` + `MAX(ts)` split, `logs` — **new form** | `SEARCH … USING COVERING INDEX` | **0.004s** |
| `ORDER BY RANDOM() LIMIT 500`, `span_trees` — **old form** | `SCAN` + `USE TEMP B-TREE FOR ORDER BY` | not run (this was the 80-min path) |

Production has no `sqlite_stat1` — `ANALYZE` has never run — so the planner is
stats-blind. These plans are structural, so that doesn't affect them, but it's
why the dev-verified plans generalised. See `docs/learnings/sqlite.md`.

## Alternatives considered

**Just lower the cadence to hourly, keep one pass.** Rejected: an 80-minute job
every 60 minutes is still a permanently busy worker. The scan had to get cheaper,
not rarer — the cadence change alone would have hidden the problem, not fixed it.

**Cache the deep results with a long TTL instead of a second job.** Rejected: the
cache key is versioned on `Splat::VERSION`, so a deploy cold-starts it and the
next settings view would trigger an 80-minute inline-ish scan anyway. An explicit
daily job makes the cost legible in `schedule.yml`.

**Approximate row counts from `MAX(rowid)`.** Rejected: retention deletes leave
holes, so it overestimates badly and unpredictably.

## Consequences

- Per-table sizes and row counts are now up to 24h stale. The settings page says
  so explicitly rather than implying everything is fresh.
- `total` shifts slightly upward: `PRAGMA page_count` counts free pages that
  `dbstat`'s table sum excludes. This is the honest on-disk number, but group
  subtotals no longer sum exactly to the headline.
- The compression estimate's `rows` is now derived (row count × the sampled
  non-null blob share) rather than an exact `COUNT(*) WHERE payload_blob IS NOT
  NULL`. It's an estimate on a page that already says "estimated".
- **Growth history is now the only record we lose.** The `total:` log line was
  the sole trace of DB growth over time (~3.2 GB/day, ~11 months of headroom
  against 1.1T free). Persisting it is tracked separately.

## See also

- `docs/learnings/sqlite.md` — the planner facts this rests on.
- `docs/learnings/tuber.md` — `idp:` semantics and reading tube stats.

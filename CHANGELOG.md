# Changelog

Splat's releases, newest first. Versions are SemVer, hand-set in
`config/version.rb` and tagged `vX.Y.Z` (see
[ADR 0004](docs/decisions/0004-file-driven-releases.md)).

This file is news: what changed, when, and what it was worth. Durable facts
about SQLite, tuber or the Sentry protocol that came out of a release belong in
[`docs/learnings/`](docs/README.md) instead, and the reasoning behind each
change stays in its commit message.

Releases before 1.16.0 predate this file — `git log v1.15.7` has them.

## 1.18.2 — 2026-09-20

One false alarm, fixed at the root.

### Fixed

- **A run's two check-ins are paired by `check_in_id`.** A cron run reports
  itself twice — `in_progress`, then `ok`/`error` — as two envelopes sharing one
  id, and sentry-ruby posts both through a multi-threaded, discard-policy
  executor. Ten milliseconds apart, they can arrive in either order. Because
  `record_check_in!` was latest-writer-wins and never read `check_in_id`, an
  `ok` landing first cleared `in_progress_since`, the late `in_progress` set it
  back to now, and nothing was ever going to clear it again: two minutes later
  the sweep called it an overrun. That is the whole of Covers' recurring
  "Monitor overrun: queue-watchdog (in progress > 2 min)" alert, for a job whose
  last recorded duration is 0.0022 seconds. One reordered pair, one alert — and
  no all-clear, because recovery resolves silently by design. Splat now drops an
  `in_progress` whose id matches the last terminal check-in (logging it, so
  production can confirm the diagnosis), and lets a terminal check-in stop only
  the clock of the run it belongs to, so a late `ok` for an earlier run cannot
  silence a newer run's genuine overrun. Heartbeats carrying no `check_in_id`
  keep the old behaviour. An `ok` that is genuinely *discarded* rather than
  reordered still alerts, correctly — a lone `in_progress` is indistinguishable
  from a real stall.

## 1.18.1 — 2026-09-12

Housekeeping, plus one piece of front-page polish.

### Changed

- **Times on the project cards are single tokens** — `2h`, not `about 2 hours`.
  The "since last error" tile is three columns wide, so Rails' prose was being
  ellipsised into `about 2 h...`, which reads as neither the number nor the
  unit. `time_ago_compact` truncates rather than rounds — 149 minutes is `2h`,
  the way a clock reads it — and both card times carry the full ISO timestamp
  as a `title`, so the precise moment stays one hover away.

### Housekeeping

- Swept nine stray files out of the repo root (scraped listings, log pastes, and
  five `test_*.rb` one-off scripts that were never run by `bin/rails test`).
  All arrived via an over-broad `git add` in 2025-11 and nothing referenced them.
- `docs/learnings/` gained the SQLite and tuber facts that came out of the
  1.18.0 incident.

## 1.18.0 — 2026-09-12

The release answering the 2026-09-12 Booko report: MCP log search wedging the
instance's whole tool surface for ~20 minutes at a time. Both reported query
pathologies turned out to be the same bug wearing different indexes — a filter
SQLite costed as selective, applied across the full retention window,
materialised and sorted before `LIMIT` could exit.

### Added

- `search_logs` takes `service` and `server_name` arguments. The query that
  actually unblocked the Booko investigation (`service = 'postgresql' AND
  server_name = 'pg01'`) previously had to be run by hand against the SQLite
  file over SSH.

### Fixed

- **Full-text log search is bounded by rowid.** The time window used to
  contribute nothing: every matching rowid across 14.4M rows was materialised,
  each row fetched at random against a 40 GB table, and the lot sorted in a temp
  B-tree before `LIMIT` applied. A 30-minute window cost exactly what a 30-day
  one did. `search_logs query="duration"` over 30 minutes: never returned → 13.4s.
  Bounds come from `MIN(id)`/`MAX(id)` over the window's own rows, so a delayed
  OTLP batch widens the range instead of being dropped.
- **Level and environment filters are bounded by the timestamp window.** A bare
  single-column index on a low-cardinality column made SQLite cost `level = ?` as
  the selective term; carrying the ordering column in the same index lets the
  range and the sort share one traversal. `level=error` over 30 minutes for 3
  rows: 34,521ms → 11ms, and it no longer queues ingest POSTs behind it. The new
  indexes are guarded by name so a large instance can build them out-of-band
  before deploying.
- **The hourly histogram rollup survives lock contention instead of burying
  itself.** Retention holds write locks on `transactions_spans` for 3+ hours; the
  rollup collided, raised five times and was buried — and a buried job holds its
  tuber idempotency key, so the next ~70 hourly puts were silently suppressed
  for three days while the tube read `ready:0`. Busy errors are now swallowed, a
  default run re-counts the last 6 hours newest-first (every write is
  `ON CONFLICT DO UPDATE`, so this is free), and a non-busy error still raises.
  No data was lost in the gap — live ingest bumps kept the hours populated.
- **Incremental vacuum actually reclaims space.** `PRAGMA incremental_vacuum(N)`
  reclaims exactly one page whatever `N` is through the Ruby driver, and the job
  called it once per database per day: 4 KB/day against deletes freeing several
  GB. `issues_events` held 3.58 GB of live data in a 26 GB file. The loop is now
  keyed off `freelist_count`, checkpoints first, pauses every 200 steps rather
  than every step, and gives up its budget rather than aborting on contention.
- **A stalled vacuum now checkpoints and retries rather than stopping.** The WAL
  pins free pages, so a freelist that stops falling isn't a finished one —
  `LogsFtsOptimizeJob` reclaimed 131,141 pages from the same database three
  minutes after the vacuum gave up on it. The pre-loop checkpoint is promoted
  from PASSIVE to TRUNCATE, and the budget goes 120s → 900s, sized to a night's
  ~776k log deletes (~1.8 GB) rather than losing ground nightly against a 31.6 GB
  backlog.

### Changed

- **Nightly maintenance runs at 2am Melbourne, not 2am UTC** — which was midday.
  Retention was holding its multi-hour write locks across the working day, and
  the weekly deep storage scan ran 13:40–21:34 local. Every job pinned to an
  hour of the night now names `Australia/Melbourne`, so DST is handled rather
  than drifting an hour twice a year. Interval and hourly jobs stay zone-free on
  purpose.

## 1.17.0 — 2026-09-11

### Added

- **Transaction ingest reads the fields a non-Rails SDK actually sends.** Ingest
  had been written against sentry-ruby and quietly assumed that was the protocol,
  so Go, Python and Node transactions arrived with no HTTP method, status,
  `db_time` or query analysis. HTTP method/status/URL now promote from
  `contexts.trace.data` (both OTel-aligned and older flat spellings) when the
  dedicated contexts are absent; the rest of `trace.data` is kept as `span_data`
  and surfaced in the detail view, the JSON API and `get_transaction`; db op
  matching widened from `db.sql.active_record` to the `db.` prefix; and db spans
  became a second source of query counts where there are no SQL breadcrumbs. The
  Rails path through all four is byte-identical to before.
- **Projects index cards carry what you'd otherwise open the project to find
  out** — cron monitor badge, issues first seen in 24h, a 24h error sparkline,
  throughput, p95 and 5xx rate. Cards drag into any order by the grip handle
  (backfilled from the old ordering, so nothing moves on deploy); the handle is a
  real button, so arrow keys reorder too.

### Fixed

- **`db:migrate` stopped emptying the cache database.** Solid Cache ships
  schema-only, but `database.yml` pointed the cache database at an absent
  `db/cache_migrate`, so `db:migrate` had nothing to run and then dumped the
  empty database over `db/cache_schema.rb` — three times, with a fresh deploy in
  between booting with no cache table. `solid_cache_entries` is now owned by a
  guarded migration, so the file round-trips.

### Performance

- The projects index sparkline caches each hour bucket under a key that names
  the hour, so a warm load scans 3 hours instead of 24: 84.6ms → 9.1ms per
  project over 240k events/day. The settling window and in-progress hour are
  always recomputed, because an event's timestamp is when it happened, not when
  it landed.

## 1.16.0 — 2026-08-29

### Changed

- **Settings: a real copy widget for the MCP command.** The `claude mcp add`
  command sat in a fixed-height `<pre>` that scrolled horizontally, hiding the
  `--header "Authorization: Bearer ..."` half that matters. It's now one widget —
  code block with its own chrome bar, Copy confirming in place, and a Show/Hide
  token toggle so the panel survives a screenshot. Display and clipboard share a
  source, so what you read and what you paste can't drift apart.
- The Settings Counts tile steps 2 → 3 → 5 columns instead of jumping straight
  to five narrow ones, with truncation as a backstop for 9-digit counts.

### Fixed

- A 40-character revision SHA overran its grid column on the About page and
  printed over the Rails version. Full hex SHAs trim to 12 (tags pass through),
  full SHA in the title.
- `transactions#show` had a `feedback` span the clipboard controller never used,
  so copying a transaction ID replaced the ID text with `<id> Copied!`.
- Cleared two standardrb offences failing the lint job.

### Dependencies

- Routine bundle update: net-protocol 0.3.0, pagy 43.6.2, rbs 4.2.0,
  rubyzip 3.5.0, thruster 0.1.26. Patch and minor only; bundler-audit clean.

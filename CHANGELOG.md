# Changelog

Splat's releases, newest first. Versions are SemVer, hand-set in
`config/version.rb` and tagged `vX.Y.Z` (see
[ADR 0004](docs/decisions/0004-file-driven-releases.md)).

This file is news: what changed, when, and what it was worth. Durable facts
about SQLite, tuber or the Sentry protocol that came out of a release belong in
[`docs/learnings/`](docs/README.md) instead, and the reasoning behind each
change stays in its commit message.

Releases before 1.16.0 predate this file — `git log v1.15.7` has them.

## 1.19.2 — 2026-10-10

Issue titles that run to several lines, as Ruby's error_highlight makes
them, stopped ntfy alerts going out and crowded the issue page.

### Fixed

- **ntfy alerts go out for multi-line titles.** The notification's Title
  header carried the whole title, and an HTTP header can't hold a line
  break. The job failed and no alert was sent for any issue whose message
  error_highlight had annotated. The Title is now the message line.
- **The issue page's title no longer runs under the Open, Resolve and
  Ignore buttons.** The status and actions move to a row above the title,
  which gets the full width.
- **The issues list fits a phone.** At 390px the page was 291px wider than
  the screen. On small screens the sparkline, count and actions now drop
  below the title.

### Changed

- **An issue is headed by its message, with error_highlight's code line and
  caret row set below it as code**, on the issue page and in the new-issue,
  reopened and burst emails. Email subjects, the issues list and the project
  overview show the message line only.
- **The issue number is a small label beside the exception type**, on the
  issue page and in the list, rather than a large column of its own.

## 1.19.1 — 2026-10-08

More numbers that described the wrong traffic, or none at all. An empty
window read as 0ms, unfiltered overall stats still pooled every project, and
the new per-host view mixed projects on a shared host.

### Fixed

- **No more 0ms for a window with no requests.** `get_transaction_stats`
  with an endpoint filled missing figures with 0. An endpoint with no
  requests, including a misspelt name, came back with every percentile at
  0ms, which made it look like the fastest endpoint in the app. The figures
  are now empty and the markdown says no transactions were found. The web UI
  had the same habit: the endpoints pages and the project dashboard showed a
  green 0ms, and a green 0% error rate, where they now show N/A.
- **Unfiltered `get_transaction_stats` no longer pools projects.** Called
  with neither `project` nor `endpoint`, it blended every project's requests
  into one set of percentiles. With one project at 150ms and another at 4ms,
  the pooled p50 was 4ms. Each project with traffic now gets its own row, in
  the markdown and as `by_project` in `structuredContent`. The pooled figures
  are empty when there's more than one project.
- **`get_host_breakdown` keeps projects apart on a shared host.** It now
  gives each project and host pair its own column, and every row names its
  project.

## 1.19.0 — 2026-10-08

Two MCP answers were about the wrong traffic. Endpoint stats blended
two projects' same-named endpoints, and nothing could separate one host's
requests from another's. This keeps both apart, and stops `get_transaction`
timing out on a request that threw no errors.

### Added

- **Per-host views in MCP.** When web01 stalled on 2026-10-08 (one worker
  was OOM-killed), no tool could say which slow requests were web01's, or
  show web01's throughput falling while web02 and web03 took its load. That
  took a hand-written query against production. Now:
  - `search_slow_transactions`, `get_transactions_by_endpoint` and
    `get_transaction_stats` take a `server_name` filter, and every slow
    transaction shows its host.
  - The new `get_host_breakdown` tool gives requests, average and max
    duration per host per time bucket, with hosts as columns. A host that
    served nothing in a bucket shows 0 rather than a gap.

  `server_name` isn't on the hourly rollups and has no index, so
  `get_host_breakdown` and a host-filtered `get_transaction_stats` read raw
  transactions. Their window is capped at 6h.

### Fixed

- **MCP endpoint stats no longer blend two projects' same-named endpoints.**
  Without a `project` argument, the endpoint tools matched on the endpoint
  name alone. Booko and C2A2 both have `ProductsController#index`, so
  `get_endpoint_summary` gave Booko's 137ms endpoint a p50 of 4ms, because
  C2A2's busier, faster traffic made up most of the pool. Nothing in the
  output said so. `get_endpoint_summary`, `get_endpoint_timeseries`,
  `compare_endpoint_performance` and `get_transaction_stats` with an
  `endpoint` now refuse when the name has requests in more than one project
  in the window, and list the projects with their request counts so the
  caller can pick one. The top-endpoints list in `get_transaction_stats` and
  the `find_n_plus_one_endpoints` worklist now have one row per project and
  endpoint, labelled with the project in both the markdown and
  `structuredContent`. The web UI was never affected: every page is scoped
  to one project.
- **`get_transaction` no longer times out looking for a request's errors.**
  On splat-booko, `get_transaction(transaction_id: "62475681")` timed out
  twice in a row. Finding the transaction was a primary-key lookup and was
  fine. The stall was the lookup after it, for the errors thrown during the
  request: its `ORDER BY timestamp` led SQLite to walk Booko's events
  newest-first along `[project_id, timestamp]`, looking for the trace. For a
  request that threw nothing, which is most of them, that meant reading every
  event the project has. The errors are now found through the
  `[project_id, trace_id]` index and sorted in Ruby. The web UI's
  transaction page used the same lookup and is fixed too.
- **Windows under an hour are labelled in minutes**, not as `0h`.
- **`get_endpoint_summary` no longer reports a DB or view-time p95 of 0ms.**
  The histograms only record total duration, so there was never a p95 for
  DB or view time to report, and the lines always printed `0ms` under a real
  average. They're gone; the averages stay.

## 1.18.3 — 2026-09-30

One MCP call froze the whole instance for three minutes. This fixes the
lookup that did it, makes the next one visible, and stops an hourly lock
fight in ingest.

### Fixed

- **MCP id lookups use the index instead of scanning the table.**
  `get_event` looked events up by `event_id` alone, but the only index is
  `[project_id, event_id]`, so every call read all 25 GB of events. On
  splat-booko one call took 179s. The sqlite3 gem holds Ruby's GVL for the
  length of a statement, so for those three minutes nothing else in the
  process ran: no web UI, no envelope ingest, no other MCP call.
  `get_transaction` had the same flaw by UUID (a scan of 132 GB of
  transactions) and by `trace_id` (a walk of the timestamp index, with or
  without a `project`). All three now pin `project_id` to every project and
  do one index probe per project. A test runs `EXPLAIN QUERY PLAN` on each
  and fails on any table scan.
- **The hourly rollup no longer blocks transaction ingest.** At :05 every
  hour, `HistogramRollupJob` held the transactions database's write lock
  for its whole aggregation. `TransactionConsumer` ran out its 5s busy
  timeout and retried for about 20s. Nothing has been lost yet, but each
  failure stalled the consumer. The aggregation is now a plain read, and
  the lock is held only for the short upsert of the results.
- **Failed ingest jobs get noticed.** A job buried after its last retry now
  raises a Sentry issue on splat-splat, named by tube and carrying the ids
  of what was dropped, instead of a log line nobody reads.
- **`get_status` quotes the real storage-stats schedule**: hourly snapshots
  and a weekly deep pass, not "~15 min" and "daily".

### Changed

- **Every MCP call is traced, named after its tool.** `/mcp` was sampled at
  10%, like envelope ingest, and every call was named
  `Mcp::McpController#handle_mcp_request`, so the 179s call left no record
  on splat-splat. Calls are now traced at the web UI rate, named
  `MCP <tool>`, and tagged with their arguments, and their request logs are
  kept.
- **sentry-ruby and sentry-rails 7.0.0**, plus routine minor and patch gem
  updates (including `mcp` 1.3.0 → 1.5.1).

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

# Maybe-todos

Ideas worth considering, not committed to. Add freely, prune ruthlessly.

## ~~Environment filter on the issues list~~ — done 2026-07-23

Shipped as the `issue_facets` table: (issue, environment|release) pairs
denormalised at ingest, filtered via `Issue.seen_in_environment`, chips on the
row, dropdown on the list, and matching `environment`/`release` args on
`list_recent_issues` / `search_issues`. Needs `splat:backfill_issue_facets` on
deploy or the filters are blind to pre-upgrade data.

Two follow-ons deliberately left out:

- **Env-scoped status-tab counts.** The tabs still show instance totals while a
  filter is active. The counts come from a 30s-cached `group(:status).count`;
  scoping them means keying that cache by environment too.
- **Env-scoped sparklines.** `Event.event_counts_by_bucket` doesn't take an
  environment, and events *do* carry the column, so this is a real filter rather
  than a facet lookup — cheap to add, just not free.

## Issue search beyond status

The issues list has status tabs and nothing else; `search_issues` over MCP is
already richer than the UI. Bring the UI up to parity: free-text on title,
exception type, environment, release, first/last seen window. The env filter and
`Issue.matching_text` (LIKE, wildcards escaped) both landed 2026-07-23, so
what's left is the free-text box, the release dropdown and the date window —
same query object, same params. Watch out for title/exception matching wanting
FTS eventually; start with LIKE and see.

## Environment-aware alert muting

Right now alerting is per-issue and global — a new issue or a burst notifies
regardless of which environment produced it. Wanted: "never email me about
staging", or per-project/per-env mute rules. Interacts with the point above:
an issue can be seen in several environments, so the rule has to be "suppress
the *alert* triggered by an event in a muted env", not "suppress the issue".
Muting must not hide the issue from the UI — it's a notification filter only.

## Per-env / per-project burst thresholds

`Setting#burst_threshold` is a single instance-wide number (`Issue#maybe_alert_burst!`).
A threshold that's right for a low-traffic side project is noise for the busy
one, and staging deserves a much higher bar (or none). Wanted: threshold
resolved per project, optionally per environment, falling back to the instance
default. Small schema change (nullable override on project, plus an env-keyed
override); the dedup window and `burst_check:` cache key stay as they are.

## Surface release comparisons in the UI

`compare_endpoint_performance` does before/after percentile comparison around a
release, and the data (releases with `first_seen_at`, hourly stats keyed by
release) already backs it — but there's no page for it. Deploy markers on
sparklines hint at the answer without giving it. Wanted: pick two releases (or
"latest vs previous") and get the endpoint-level p50/p95 delta table, ordered by
regression size, plus new/resolved issues between them. This is the "did the
deploy make things worse?" page.

## Slow-transactions search page (match the MCP)

`search_slow_transactions` has filters the UI doesn't expose. Same pattern as
issue search: the agent-facing surface is ahead of the human-facing one. A
filterable slow-request list (endpoint, env, release, min duration, time range)
using the same query object as the MCP tool, so the two can't drift.

## Queue-health self-monitoring (buried jobs)

Splat watches everyone else's health and not its own queue. Tuber buries jobs
that fail repeatedly; today nothing notices. Wanted: buried/delayed counts on
the health endpoint and the settings page, and an alert when buried > 0 or the
ready count stays above a threshold for N minutes. Care needed to avoid the
obvious loop — the alert path must not depend on the queue that's stuck (send
inline, or at least degrade to a log + health-endpoint signal). Ties into the
existing degraded-ingestion indicator rather than being a second mechanism.

## Cross-link monitors ↔ performance endpoints

Context (2026-07-18): booko's `meili_flush` daemon now has both a heartbeat
monitor and a `meili_flush.cycle` performance endpoint; the detailer will
likely follow (endpoint `detailer` + a monitor). The two views describe one
logical service — liveness vs work-unit timing — and someone on either page
plausibly wants the other.

- **Endpoint detail page**: small status chip in the header — associated
  monitor's state (ok / error / missed) and time since last beat, linking to
  the monitor page. Context only; must read as liveness, not perf health
  (green chip + tripled p95 shouldn't look like "all good").
- **Monitor page**: link to the associated endpoint(s), maybe a tiny p50/p95
  sparkline, plus recent errors for the same component.
- **Association is explicit, not name magic**: slugs don't reliably match
  transaction names (`meili_flush` vs `meili_flush.cycle`; `detailer` matching
  is luck). One monitor → many endpoints. UI: pick endpoints from the list of
  known endpoint names already in the DB (typo-proof), free-text fallback only
  for endpoints that haven't emitted yet.
- **Don't fuse the states**: alive-but-slow and dead-with-great-last-numbers
  are both real; adjacent and linked, never one merged status/alert.

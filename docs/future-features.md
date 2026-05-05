# Future Features

A running wishlist of Sentry-style features worth considering for Splat. Sorted
by **value vs. effort**, with the simplicity-first ethos in mind: anything that
adds heavy infra (session replay, profiling) or multi-tenant scaffolding (teams,
assignments) is parked at the bottom.

When picking up a feature, copy its section over to `docs/improvements.md` (the
backlog with implementation notes) and mark it as `In progress` here.

## Done ✅

- **24h sparklines** on issues list and top endpoints — at-a-glance "spiking now
  vs. background noise" via DuckLake bucket aggregation. (Commit `a4c527d`)
- **Release tracking + deploy markers** — `Release` model, `Issue.first_seen_release`
  / `last_seen_release`, and dashed deploy lines overlaid on every 24h sparkline.
  Booko already sends `release` via Sentry's standard config. (Commits `485a664`,
  `15f3df7`)
- **N+1 query detection** — surfaced at the dashboard level. (Commit `1dc7c13`)
- **Span waterfall** — full per-transaction span tree stored in DuckLake
  (columnar, partitioned by year+month, with RLE/dictionary compression),
  rendered as a tiered waterfall on the transaction detail page. SQL
  normalization at ingest doubles as PII scrubbing — literal values never
  reach disk. Capped at 1000 spans per transaction; 30-day retention.

## High value, low effort (next)

### Webhook notifications on new / regressed issues
Slack/Discord (and generic) webhooks fire when:
- An issue is created (first occurrence of a fingerprint)
- An issue regresses (auto-reopened from `resolved`, OR `last_seen_release` !=
  `first_seen_release` after being stable for N hours)

One `Webhook` model (`project_id`, `url`, `event_types`, `secret`), one job, done.
Pairs naturally with release tracking — "this regressed in deploy v1.2.5" is a
much better Slack ping than just "this happened again."

### PII scrubbing on ingest
Regex-based scrubbing of common patterns (emails, credit-card-like numbers,
JWT-shaped tokens) over `payload` keys before storage. Runs in
`ProcessEventJob` and `ProcessTransactionJob`. Configurable allow/deny list per
project. Important if Splat ever hosts events from anyone but us.

### GitHub OAuth2 login (with org-membership allowlist)
Add GitHub as an alternative identity provider so anyone with a GitHub account
in an allowed org can log in — no per-user email allowlist maintenance.

- **Auth flow:** OAuth2 authorization-code with `read:user user:email read:org`
  scope. Callback handler exchanges code for token, fetches `/user` and
  `/user/orgs`, applies allowlist.
- **Allowlist env var:** `SPLAT_ALLOWED_GITHUB_ORGS=booko,booko-staff` — mirrors
  the existing `SPLAT_ALLOWED_DOMAINS` shape.
- **Effort:** ~half a day. Splat's auth is currently a hand-rolled OIDC
  controller (`app/controllers/oidc_auth_controller.rb`), so we either
  generalize it into an OAuth2 base + provider subclasses, or run a small
  parallel OAuth2 controller for GitHub. The latter is faster; the former is
  cleaner if we anticipate adding more providers.
- **Caveat:** Org members behind SAML SSO must have authorized the OAuth app
  for the org separately, otherwise `/user/orgs` won't list it. Document this
  in setup instructions.

### `DuckLake::Issue` cleanup (internal)
Drop the issue mirroring entirely. Every event ingest currently writes a new
snapshot row that readers have to `MAX(updated_at)` over to recover current
state — and nothing in the codebase actually queries DuckLake for issues. AR is
the source of truth and the issues table is small. Ripping this out simplifies
ingest and removes a foot-gun. Touches:
- `app/jobs/process_event_job.rb` (remove the `DuckLake::Issue.insert`)
- `app/models/duck_lake/issue.rb` (delete)
- `db/ducklake_schema.sql` (remove the `issues` table block)
- DuckLake catalog cleanup (`DROP TABLE issues`) at deploy

## Medium effort, big "feels like Sentry" payoff

### Breadcrumbs timeline view
Already in the event payload — just needs rendering on the event detail page.
Vertical timeline, one row per breadcrumb (timestamp, category, level, message,
data). Adds enormous "what was the user doing right before this?" value.

### User context: "X users affected"
`user.id` / `user.email` are in payloads. Add `user_id_hash` (sha256, for
privacy) to events, count `DISTINCT user_id_hash` per issue. "12 users hit this"
on the issue card; "show me only errors for user 42" filter. Pairs with PII
scrubbing.

### Suspect commits
If `release` is a git SHA (Booko's release prefixes a timestamp but ends in a
SHA), then for any new issue we can compute `git log <previous_release>..<this_release>`
and surface the diff. Needs a way to read the project's git repo —
either a checkout path on the Splat host, or a GitHub API token + repo URL on
the project record.

### Cron / heartbeat monitoring
A `Monitor` model: `name`, `expected_interval` (e.g., "every 1h"),
`grace_period`, `last_ping_at`. Endpoint at `POST /api/:project/monitors/:slug/ping`.
Background job checks for monitors whose `last_ping_at + expected_interval +
grace_period < now` and creates a synthetic issue. Same notification pipeline as
real errors.

## Skip (against the simplicity ethos)

- **Session replay** — heavy storage, big infra, dubious ROI single-tenant.
- **Profiling** (continuous or on-demand) — same.
- **Source maps / minified-JS deobfuscation** — only useful if we ingest
  browser-side errors, which we don't really do.
- **Issue assignment / comments / teams / roles** — explicitly out of scope per
  CLAUDE.md ("no users, teams, or project management").
- **Custom dashboards / saved searches** — premature; URL params get you 80%
  of the value.

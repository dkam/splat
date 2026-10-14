# Changelog

Splat's releases, newest first. Versions are SemVer, hand-set in
`config/version.rb` and tagged `vX.Y.Z` (see
[ADR 0004](docs/decisions/0004-file-driven-releases.md)).

This file is news: what changed, when, and what it was worth. Durable facts
about SQLite, tuber or the Sentry protocol that came out of a release belong in
[`docs/learnings/`](docs/README.md) instead, and the reasoning behind each
change stays in its commit message.

Releases before 1.16.0 predate this file — `git log v1.15.7` has them.

## Unreleased

## 1.23.0 — 2026-10-14

Stack frames link to their line in the project's repository, at the commit
the event's release names. Ingest no longer turns envelopes away while Tuber
is down: they wait on disk and are queued once it answers again.

### Added

- **Stack frames link to their line in your repository.** Give a project a
  source link template on its edit page, such as
  `https://github.com/org/app/blob/{sha}/{path}#L{line}`, and each of the
  app's own frames links to its line at the commit the event's release names.
  The release has to carry the full SHA, alone or as build metadata
  (`1.4.0+<sha>`); a release without one gets no links, unless the template
  names a branch instead of `{sha}`. Library frames stay unlinked, since
  their paths aren't in your repository.

### Changed

- **Nothing is lost while Tuber is down.** What ingest can't enqueue is kept
  on disk in `storage/spool/`, answered with a `200`, and put back on its
  tube by the worker once Tuber answers. It used to be a `503`, after which
  SDKs drop the envelope. The spool is capped at 1 GB (`SPLAT_SPOOL_MAX_MB`);
  past it, ingest answers `503` as before. `/_health` reports `degraded`
  while anything is spooled, and `get_status` shows the spool.

## 1.22.0 — 2026-10-14

MCP queries are stopped after 15 seconds, so one wide search can no longer
hold Splat for minutes, and the web service runs as two processes. Ingest
answers SDKs the way Sentry does: a `503` when it can't take an envelope, a
`413` over Sentry's size limits, rate limits for streams switched off, and
the old `/store/` endpoint.

### Added

- **The `/api/:project_id/store/` endpoint**, where Sentry's clients posted
  one event at a time before envelopes: the raven-era SDKs and third-party
  clients that never moved on. Those got a `404`. The body is read as Sentry
  reads it (JSON, or base64 of JSON or of zlib-compressed JSON) and goes on
  as an envelope, so the size limits, the `503`, the rate limits and
  forwarding apply to it unchanged.

### Changed

- **SDKs stop sending what Splat would throw away.** With a stream switched
  off in Settings, every ingest response now carries Sentry's
  `X-Sentry-Rate-Limits` header for it: `error` for events, `transaction`,
  `log_item` for logs. An SDK then stops sending those for a minute at a time,
  rather than building, compressing and posting them for Splat to drop. Logs
  are off by default, so this mostly stops log batches from SDKs with logs
  turned on. A stream switched back on is sent again within a minute. A
  project that forwards gets no header, because its envelopes go on whole.
- **Ingest answers `503` when it can't reach tuber.** It used to answer `200`,
  so the SDK counted an envelope as delivered while Splat dropped it. Server
  SDKs still don't send it again, but they now record it as lost. The OTLP
  logs endpoint answered `500` instead, after which a collector drops the
  batch. It now answers `503` too, and a collector sends the batch again.
- **Ingest has a size limit: Sentry's own.** A request body over 20 MB as
  sent, or over 100 MB once decompressed, is answered `413` on both the
  envelope and OTLP logs endpoints. Decompression stops at the limit, so a
  few kilobytes of gzip, deflate, Brotli or Zstandard that would expand to
  gigabytes no longer get the chance to fill a web process's memory. An SDK
  stays under these limits for Sentry, so nothing it sends is refused.
- **An envelope whose gzip or deflate is corrupt is dropped with a `200`**,
  logged, as Brotli and Zstandard already were. It used to raise, for a
  `500`. On the OTLP endpoint a corrupt gzip body is a `400`.
- **MCP queries are stopped after 15 seconds**, with an error telling the
  model to narrow its window or add filters. One wide `search_logs` used to
  hold its Puma process until it finished — about 20 minutes on 2026-09-12,
  with every other tool call and the UI waiting behind it.
  `SPLAT_MCP_STATEMENT_TIMEOUT` sets the cap in seconds.
- sqlite3 2.9.6 → 2.10.0, which fixes `statement_timeout` (it stopped every
  query at once, sqlite3-ruby#737). The Gemfile now requires 2.10.
- **The compose example runs two Puma processes** (`WEB_CONCURRENCY: 2`), so
  the UI and ingest keep answering while the other process is stuck on a long
  query. More threads couldn't do it: the sqlite3 gem holds Ruby's global lock
  for the whole of a statement.

### Fixed

- **A compressed envelope sent as `Content-Type: application/json` is read.**
  Rails parsed the body as JSON form parameters on the way to the project id,
  and a gzip body failed that before Splat saw it.
- **Envelopes compressed with Zstandard are read.** The controller required
  a file the zstd gem doesn't have, so every one was dropped with "Zstd gem
  not available".

## 1.21.1 — 2026-10-13

New-issue emails are sent again, and ntfy alerts for new and reopened issues
are no longer dropped.

### Fixed

- **New-issue emails are sent again.** An issue's alerts were put on tuber
  inside the transaction creating it, and the worker picked the mail job up
  before that committed, so every new-issue email failed with "Couldn't find
  Issue". Since 1.21.0 it lost that race on every new issue. ntfy's
  new-issue and reopened alerts were dropped the same way, without an error.
  Jobs are now queued only once the transaction that queued them commits.

## 1.21.0 — 2026-10-12

Ingest and maintenance run in one `worker` container, forked from one boot of
Rails, at about half the memory of two. Workers stop within seconds of TERM
instead of being killed at the end of Docker's grace period. And a log
attribute is indexed for search only up to its first 512 characters, so
sentry-rails' query logs no longer swamp the logs search index.

**Upgrading:** to run the single worker, replace the `ingest` and
`maintenance` services in your compose file with `compose.yml`'s `worker`
service, then `docker compose up -d --remove-orphans`. A compose file left
as it is keeps working.

### Changed

- **Ingest and maintenance run in one `worker` container.** `bin/worker all`
  boots Rails once and forks a process per role, so a heavy maintenance job
  still can't freeze ingestion, but the two share the memory Rails loaded:
  measured locally, about half of what the two separately booted processes
  take. The worker restarts a process that dies, with a growing pause while it
  keeps dying, and reports each death to Sentry. If the container runs out of
  memory, the kernel kills the maintenance process first. To switch, replace
  the `ingest` and `maintenance` services with the `worker` service from
  `compose.yml` and run `docker compose up -d --remove-orphans`, which removes
  the old two. `bin/worker ingest` and `bin/worker maintenance` work as before,
  for anyone who'd rather keep them separate.
- **Workers stop within a few seconds of TERM.** An idle consumer waited up to
  30 seconds for tuber before noticing it had been asked to stop, longer than
  Docker's 10-second grace, so every deploy ended with the workers killed
  rather than stopped. It now asks tuber every 5 seconds.

### Fixed

- **A long attribute no longer floods the logs search index.** Only the first
  512 characters of each attribute value are indexed for search. sentry-rails'
  query logs carry their whole SQL statement as an attribute, and a bulk
  upsert's runs to ~400 KB of near-unique numbers: in production three such
  query types were 0.6% of logs but two-thirds of all indexed attribute text.
  The full value is still kept and shown on the log page; only searching past
  the first 512 characters stops matching. Applies to new logs; the existing
  index shrinks as old logs age out.

## 1.20.0 — 2026-10-12

Tuber runs Splat's recurring jobs, from tuber 0.16, and Settings and
`/_health` say when nothing does. OIDC is configured from the provider's
issuer alone, checked against its discovery document. Errors are grouped by
the function in your code they came from rather than a gem's line, and a
chained exception by the exception actually raised, with its causes shown on
the event. What eight real SDKs send is now replayed through ingest by the
tests, and the replay found seven ways their events were lost or misread.
Envelopes are read by byte length, as the spec says. SQLite's page cache
drops to 2 MB a connection, growing only while ingest catches up on a
backlog. And a transaction's view time is its template render, no longer the
whole controller action.

**Before upgrading:**

1. **Upgrade tuber to 0.16 first**, backing up its binlog: the first start
   on an older binlog needs `--migrate-wal`, and older tubers can't read the
   result. "Recurring jobs" in the README has the steps. Staying on an older
   tuber, start the `scheduler` service with `--profile old-tuber`, or
   nothing fires the jobs.
2. **Using OIDC, replace `OIDC_DISCOVERY_URL` with `OIDC_ISSUER` in `.env`**
   before `up -d`, or the UI returns `503`. See below.

### Changed — breaking

- **`OIDC_DISCOVERY_URL` is replaced by `OIDC_ISSUER`.** The provider is now
  configured from its issuer URL alone; discovery is fetched from
  `OIDC_ISSUER` + `/.well-known/openid-configuration`. **Update `.env` before
  the next `up -d`**: with the old variable set and the new one missing, all
  three OIDC variables are no longer present, so the instance boots
  `:misconfigured` and the UI returns `503`. Ingestion, `/mcp` and `/_health`
  keep serving, as they do for any half-configured deploy.

  Set `OIDC_ISSUER` to the `"issuer"` field of your provider's own discovery
  document, copied exactly — trailing slash and path included. It is what the
  `id_token`'s `iss` claim is verified against, and it is no longer read back
  from discovery: the discovery document's issuer is checked against it, as
  OIDC Discovery 1.0 §4.3 requires, so a wrong value is reported rather than
  quietly corrected — on the login page, naming the issuer the provider gave,
  before anyone is sent off to log in.
  Moving the old discovery URL across unchanged still builds the right
  discovery URL (the well-known suffix is stripped) but fails the issuer check.

  One variable instead of two that had to agree.

- **The undocumented manual-endpoint escape hatch is gone from the README.**
  `OIDC_AUTH_ENDPOINT`, `OIDC_TOKEN_ENDPOINT`, `OIDC_USERINFO_ENDPOINT` and
  `OIDC_JWKS_ENDPOINT` were documented but never read by any code. Nothing
  changed in behaviour; the docs stopped claiming otherwise.

### Changed

- **Tuber runs the recurring jobs, from tuber 0.16.** The web container hands
  `config/schedule.yml` to tuber as it starts (`bin/rails
  splat:schedule:sync`), and tuber puts each job on its tube at its time, with
  no Splat process involved. If tuber comes back from a restart without it
  (no binlog), the ingest worker puts it back. **The `scheduler` service is
  only needed with a tuber older than 0.16**, and `compose.yml` now starts it
  only under `--profile old-tuber`. Run on 0.16, `bin/scheduler` checks
  tuber holds the schedule and idles; on an older tuber it fires the jobs
  itself, as before, and hands them to tuber if tuber is upgraded under it.
  **Upgrade tuber first**: 0.16's first start on an older binlog needs
  `--migrate-wal`, and older tubers can't read the result, so back the binlog
  up. "Recurring jobs" in the README has the steps.
- **Settings lists the scheduled jobs**: what fires each one (tuber,
  `bin/scheduler`, or nothing), when a worker last ran it, when it fires
  next, and whether it's late or stuck behind a buried job. A red banner says
  when nothing fires them. Workers record each run in a new `schedule_runs`
  table, whichever of the two put it.
- **`/_health` is `degraded` when the recurring jobs have stopped.** Its new
  `scheduler` field goes `late` when `monitor_evaluation`, which runs every
  minute, hasn't run for five minutes, counted from boot if it never has.
  Monitor evaluation is what raises Splat's own alerts, so this had no other
  way to be noticed. An Uptime Kuma check on `$.queue_status` alone won't see
  it; check `$.status` too.
- **Splat talks to tuber through the `tuber` gem (0.7)** rather than a fork of
  beaneater. Two behaviours change. A put refused because tuber's storage
  budget is spent (`OUT_OF_STORAGE`) now raises, where before it looked
  accepted and the data was lost without a word. And a delete, release or
  bury cut off by a tuber restart isn't re-sent: the gem can't know whether
  the first one landed. The worker reconnects as before, and jobs from the
  batch it was finishing can be processed a second time.
- **A second scheduler is harmless.** Every schedule entry now carries an
  `idp:` key with a 30 s cooldown, and the two `every` entries are cron lines,
  so schedulers fire each entry on the same second and Tuber turns the
  duplicate into a no-op. `data_retention` and `cleanup_expired_oidc_sessions`
  gain keys, so a buried retention run now holds back the next night's too —
  and is reported.
- **SQLite's page cache is 2 MB per connection, not 20 MB, and grows only
  where it pays.** A connection fills its cache and keeps it, and the ingest
  worker alone holds ~17 connections, so 20 MB each set a ~340 MB ceiling.
  Each ingest consumer now raises the cache on the database it writes while
  its reserves come back full (a backlog), and drops it 60 s after the last
  full one. In a 2M-row benchmark the small cache cost nothing on reads and
  ~12% on inserts at random index positions. Each consumer logs jobs and
  ms/job at each size, plus process memory, once a minute — to the container
  log and to `SENTRY_DSN` — so the trade can be judged on real traffic.
  `SPLAT_SQLITE_CACHE_KB` and `SPLAT_SQLITE_CACHE_BOOST_KB` set the two sizes;
  `SPLAT_SQLITE_CACHE_KB=20000` restores the old behaviour.
- **An error is grouped by its type and the function in your code it came
  from.** Splat used the innermost frame's file and line. When that frame was
  inside a gem, every caller shared it: every `ActiveRecord::RecordNotFound`
  from `find` was one issue, wherever it was called. And an edit that moved
  the line split the issue in two after the next deploy. Now it's the
  innermost frame marked as your code, by module or file and function, with
  no line number. Rails' compiled template methods carry a number that
  changes with every restart, which is stripped, as are the numbers and
  hashes in the names of classes the JVM generates — reflection accessors,
  proxies, Spring and Hibernate subclasses, lambdas. A core method like
  `Hash#fetch`, which sentry-ruby reports at its caller's line as if it were
  your code, is passed over for the caller. With no frame marked as your code
  (sentry-java, unless configured), the whole stack groups; with no stack
  trace at all (sentry-rust's default), the type and the message — both as
  Sentry does.
- **Messages that differ only in numbers, UUIDs or hex ids are one issue.**
  "Timeout after 3021ms for user 4412" no longer opens an issue per user.
  The title is still the first message seen.
- **Upgrading: existing issues carry over.** Each is re-keyed by its next
  event, keeping its history and status, so it doesn't open again as new or
  send a "new issue" email. Where one old issue collected errors from several
  places — a gem frame shared by many callers — the first to recur keeps it,
  and the rest open as new issues as they recur, each with its notification.
  The old catch-all "Unknown Error" issue isn't carried over.

### Fixed

- **A chained exception is titled, typed and grouped by the exception
  raised.** Splat read the root cause, `exception.values[0]`, where the raised
  exception is the last. So `rescue Net::ReadTimeout; raise PaymentFailed`
  was filed as a `Net::ReadTimeout`, and every timeout wrapped anywhere landed
  in one issue. The event page, `get_issue` and `get_event` now show the
  raised exception and its stack trace. An issue grouped the old way is
  re-keyed by its next event rather than opened again as new; where one old
  issue covered several wrappers, the first to arrive keeps it. Rails template
  errors become `ActionView::Template::Error`, with the same message.
- **Messages from sentry-java and sentry-dotnet are no longer lost.** Both
  send `message` as an object, which grouping hashed as a string: the job
  raised `TypeError`, retried and was buried. They're titled by their
  formatted text and grouped by their template, so "Payment %s failed" is one
  issue whatever the payment.
- **Python logging errors are no longer all one issue.** sentry-python's
  logging integration sends `logentry` rather than `message`. Splat read no
  message at all, titled each one "Unknown Error" and grouped them together.
  New ones are titled and grouped by their message; the existing "Unknown
  Error" issue stops growing.
- **Envelopes are read by byte count, not by line.** The parser split the
  body on newlines and guessed where a payload ended. It counted each new line
  twice, so it often guessed early, and a payload holding newlines came apart:
  - an attachment with a line that looked like JSON cost the whole envelope,
    including the event sent with it;
  - pretty-printed JSON was cut off partway and queued as a string.

  Each payload is now read as exactly its `length` in bytes, as the envelope
  spec requires. Zero-length items, which the spec allows, are accepted
  rather than rejecting the envelope. A payload that runs past its `length`,
  or ends short of it, is rejected as malformed, as Sentry's own ingest does.
- **An event or transaction payload that isn't a JSON object is dropped at
  the door.** It used to be queued, then fail in the consumer on every retry
  until tuber buried it.
- **A transaction's view time is its template render, not the whole
  controller action.** Splat read view time from sentry-rails'
  `view.process_action.action_controller` span, which despite its name times
  the whole action, queries included — so database and view time together
  came to more than the request: a 142 ms page showed 49% database and 96%
  view. View time is now the template render less the queries run during it,
  so the two never exceed the request. It falls short of Rails' own "Views:"
  figure by the layout, which sentry-rails sends no span for; that time shows
  as other. An action that renders no template, such as a JSON API, has no
  view time. Transactions already stored keep the old figure until retention
  removes them.
- **Database and view time are no longer blank when a client sends a
  measurement of its own.** Splat read them from the spans only when the
  client sent no measurements at all, so any custom metric switched them off.
  A client's own `db` or `view` measurement still wins; the spans fill in
  whichever is missing.
- **The span waterfall no longer draws a Rails request as one long render.**
  The controller action span was coloured as a view render; it's drawn as
  other now, and `get_transaction_spans` points at `template` for renders
  rather than `view`.
- **A scheduled job held back by a buried earlier run is reported.** A buried
  job keeps its `idp:` key, so every later run of that entry creates nothing.
  Tuber said so in its reply (`INSERTED <id> BURIED`) and the scheduler threw
  the reply away; on 2026-09-09 that hid a dead hourly rollup for three days.
  Each lost run now logs an error and reaches Sentry, one issue per entry, so
  the issue's count is the number of runs lost.
- **An envelope with a header that is JSON but not an object is logged as an
  invalid envelope,** not as an error inside Splat with a backtrace. It's
  dropped either way.
- **`{{ default }}` in an SDK fingerprint stands for Splat's own grouping.**
  It was kept as literal text, so every event sharing the rest of the
  fingerprint went into one issue, whatever its error.
- **An SDK fingerprint sent as a string rather than a list no longer fails
  ingest.** It raised `NoMethodError`, retried, and was buried.
- **sentry-go's errors are ingested.** sentry-go sends `exception` as a bare
  list rather than `{"values": [...]}`, which the protocol allows and Splat
  didn't: every Go error failed ingest, retried, and was buried.
- **An event's page shows breadcrumbs sent as a bare list.** @sentry/node,
  sentry-go, sentry-java and sentry-dotnet all send them that way, and the
  page and MCP's `get_event` failed with an error for any of their events
  carrying one. A transaction carrying them would have failed ingest.
- **MCP's `get_event` takes breadcrumb times written as text.** Python, Go,
  Java and .NET send ISO 8601 strings, not epoch seconds; `get_event` failed
  on any event with a breadcrumb, which sentry-python's logging integration
  records by default. The page showed the raw string, and now shows the time
  as for the others.
- **@sentry/node's parameterised messages are shown filled in.** It sends the
  template and its params and leaves the text for the server to make;
  Splat showed `Card %s declined`. It's filled in now as Sentry does it.
- **sentry-go's stack frames show their file.** They carry only `abs_path`,
  and each showed as "unknown".
- **Transactions from sentry-python, sentry-go, sentry-dotnet and sentry-rust
  are ingested when they have a database span.** These SDKs send span times
  as ISO 8601 strings (sentry-rust the end time only), and Splat subtracted
  them as numbers: the transaction failed ingest, retried, and was buried.
  Their spans were also put in no particular order in the waterfall, sorted
  by the year they start with.

The last seven were found by replaying what eight SDKs — Ruby, Python, Node,
Go, Java, .NET, Rust and PHP — actually send, now recorded in
`test/fixtures/files/sdk_envelopes/` and run through ingest by the test suite
(`script/sdk_envelopes/` records them again).

### Added

- **An event shows what its exception was caused by.** Each cause in the
  chain gets a section below the stack trace: its type, its message and its
  own stack trace, or "Same stack trace as above" where it shares the one
  just shown, as a template error's cause does. The top of the page links to
  each cause, so the root cause is visible without scrolling. `get_event`
  lists the same, and `get_issue` names each cause.

## 1.19.4 — 2026-10-10

The overview's recent issues now use the issues list's row, and an issue
reported as a message is labelled instead of blank.

### Fixed

- **A long exception type no longer breaks a row's top line.** A type like
  `ActionController::Redirecting::OpenRedirectError` wrapped the line, so
  the count and buttons sat on a line of their own at the left of the row.
  The type is now cut off with "…", with the full name on hover.

### Changed

- **The overview's recent issues use the issues list's row.** It is one
  shared template, so the two can't drift apart again. The overview gains
  the list's Resolve and Ignore buttons and its environment chips.
- **An issue reported as a message is labelled "Message".** It has no
  exception type, which used to leave its id alone at the start of the row.
  The badge appears on the issues list, the overview and the issue page.

## 1.19.3 — 2026-10-10

The rest of the UI catches up with 1.19.2's issue page. Events are headed
by their message, issue rows give their title the full width, and the
event page, the overview and the header fit a phone.

### Fixed

- **The event page fits a phone.** Its View Issue and Delete Event buttons
  were pushed off the right edge, and the page was 395px wider than the
  screen. It now has the issue page's header: the id, event ID and
  environment in a small row with the buttons on the right, and the
  message across the full width below.
- **The overview's Recent Events rows hold together.** Each row was a link
  with its issue's link inside it, which browsers split apart. That left an
  empty row above each event, its details scattered below, and at 390px a
  page 185px wider than the screen.
- **The header fits a phone.** Its right-hand controls ran 109px past the
  edge, so the status badge and the sign-in controls were cut off. Below
  `lg` the labels give way to icons and badges, each with a tooltip.
- **"1 event", not "1 events"**, on the issues list and the overview.

### Changed

- **Events are headed by their message, with error_highlight's code line
  and caret row set below as code.** That applies to the event page and to
  the event page's exception box. On a phone the code scrolls sideways
  rather than wrapping, so the carets stay under the code. The event rows
  on an issue's page, the overview's recent events and a transaction's
  errors show the message line only.
- **Issues list rows take the issue page's shape.** The id, type and
  badges sit at the left of a top row, with the sparkline, count and
  buttons at the right. The title runs across the full width below, where
  it used to get two thirds of the row. The event count is shown once
  rather than twice.
- **The overview's recent issues and events lead with their message.** The
  id moves to sit beside the exception type, so the titles line up.

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

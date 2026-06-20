# SQLite Migration Review — Action List

Branch: `sqlite-everything` (commit `ecb4296` + uncommitted working tree)
Review date: 2026-06-11
Context: DuckDB/ParquetLake analytics layer dropped, replaced with two SQLite DBs
(`issues_events`, `transactions_spans`) using zstd dict-compressed JSON payloads
and DDSketch histograms.

**Decision on record:** production history is **disposable** — no backfill needed,
the purge migration is correct as-is (see #18).

Work order: P0 → P1 → P2 → P3 → P4. Suggested first step: #10 (green test suite to
verify against), then #1, then the ingest cluster (#2–#4).

---

## P0 — Visible breakage (do first)

### 1. Fix transaction waterfall 500 (`s["duration_ms"]`)
`app/views/transactions/_waterfall.html.erb:24` reads `s["duration_ms"]` but
`TransactionsController#show` now passes Span AR models; `duration_ms` is a
computed method (`app/models/span.rb:19`), not a column, so AR's `#[]` raises
`MissingAttributeError` and the page 500s.
**Fix:** call `s.duration_ms` in the view, or merge it in the controller like the
MCP path does at `mcp_controller.rb:737`.

### 10. Repair red test suite (ParquetLake/DuckLake leftovers)
`test/jobs/parquet_lake/retention_job_test.rb` and `compaction_job_test.rb` raise
`NameError: uninitialized constant ParquetLake` at load — the whole suite aborts.
`test/controllers/mcp/mcp_controller_test.rb:109` stubs deleted
`DuckLake::Transaction`.
**Fix:** delete the two parquet_lake test files; update/replace the MCP test stub
for the new Transaction analytics path. Do this early so the rest can be verified.

---

## P1 — Silent data corruption in ingest

### 2. Fix transaction redelivery double-write (spans + histogram)
`transaction_consumer.rb:29` comment claims `RecordNotUnique` on redelivery, but
`Transaction.create_from_sentry_payload!` (`transaction.rb:83`) uses
`find_or_initialize_by` and silently returns the existing row. Consumer then
re-runs `Span.insert_all!` (spans have no unique index → permanent duplicates)
and `Histogram.bump_many!` (double-counts the live hour).
**Fix:** return an "already existed" flag from `create_from_sentry_payload!` and
skip span insert + bump when set; or add a unique index on spans + proper rescue.

### 3. Fix event consumer poison-pill on redelivery
`event_consumer.rb:28` rescues only `ActiveRecord::RecordNotUnique`, but `Event`
validates uniqueness of `event_id` scoped to `project_id` (`event.rb:15`), so a
redelivered job raises `RecordInvalid` from the validation SELECT before hitting
the DB unique index. Falls through to the generic rescue, retries 5×, buried.
**Fix:** rescue `RecordInvalid` too, or drop the model-level uniqueness validation
and rely on the DB index + `RecordNotUnique`.

### 4. Fix double-encoded span tags/data
`transaction_consumer.rb:128` `build_span_row` pre-encodes tags/data with
`.to_json` before `Span.insert_all!`, but Rails 8 `InsertAll` re-serializes through
the json column type, double-encoding. `Span#tags/#data` read back as a JSON
String instead of a Hash (verified vs activerecord 8.1.3).
**Fix:** pass the raw Hash and let the json type serialize once. Remove the
misleading workaround comment at lines 111–114.

---

## P1 — Silent wrong data in dashboards / MCP

### 5. Fix nil project_id percentiles (`histogram_percentile`)
`transaction.rb:111` binds `project_id` directly (`project_id = ?`) in both CTE
arms; nil renders `project_id = NULL` and matches zero rows. MCP
`get_transaction_stats` (`mcp_controller.rb:666`) and `get_endpoint_summary`
(`:766`) call `percentiles_for_endpoint` with default `project_id: nil` → p50/p95/
p99 report 0ms.
**Fix:** conditional `AND project_id = ?` bound only when present (NOT `COALESCE`,
which is non-sargable — see #16). Consider merging `histogram_percentile` and
`global_percentile` into one parameterized query here.

### 6. Fix MCP `get_endpoint_timeseries` key mismatch crash
`mcp_controller.rb:1441` `format_endpoint_timeseries` reads symbol keys
(`b[:count]`, `b[:bucket_start]`, `b[:avg_duration]`) but
`TransactionAnalytics#time_series_for_endpoint` now returns string-keyed hashes
`{"bucket","count","p50","p95","p99"}` with no `bucket_start`/`avg_duration`. Every
call raises `NoMethodError` (`nil.zero?`).
**Fix:** update the formatter to the new string keys/shape; drop
`bucket_start.strftime` — `bucket` is now an integer index.

### 7. Restore dropped endpoint-stats keys (dashboards + MCP)
`stats_by_endpoint_with_impact` (`transaction_analytics.rb:98`) and
`endpoints_by_n_plus_one` (`:136`) no longer return `p50/p95/p99_duration`,
`n_plus_one_count`, `avg_queries`, `max_queries`, `total_count`, `n_plus_one_pct`
that the deleted DuckLake version produced. Consumers still read them:
`endpoints/index.html.erb:130-157`, `projects/show.html.erb:204`,
`endpoints/n_plus_one.html.erb:42-68`, MCP `format_transaction_stats:1186` and
`format_n_plus_one_endpoints:1421-1426`.
**Fix:** add the columns back to the SELECTs, or update every consumer. Decide
which keys are still wanted (percentiles, query counts, N+1 counts).

### 8. Fix MCP `search_slow_transactions` http_method + substring
`mcp_controller.rb:692` still parses `http_method` and the schema (`:382`)
advertises `endpoint` as a case-insensitive substring match, but the new
`Transaction.slow` has no `http_method` param and matches `transaction_name` with
exact equality.
**Fix:** restore `LIKE %…%` substring matching; either re-implement `http_method`
filtering or drop it from the handler + schema so contract matches behavior.

### 9. Fix endpoints header percentiles ignoring `?name=`
`endpoints_controller.rb:26` computes header p50/p95/p99 via
`Transaction.percentiles`, which has no `transaction_name` filter; the old
`ducklake_percentiles_for` added `AND transaction_name LIKE ?` when `@name_query`
was set. With `?name=` the header cards show project-wide percentiles while the
table below is filtered.
**Fix:** add an optional name filter to `percentiles` (or a name-scoped variant)
and pass `@name_query`.

---

## P2 — Ops / deploy

### 11. Add zstd CLI to Dockerfile runtime image
`Dockerfile:20` runtime image lacks the zstd CLI, but
`Compression::DictTrainingJob#train_candidate` shells out to `zstd --train` via
Open3 (`dict_training_job.rb:114`). Scheduled `DictDriftJob` → `DictTrainingJob`
raises `Errno::ENOENT` in prod, retries, buries jobs; retraining never works.
**Fix:** add `zstd` to the apt-get install list on line 20.

### 12. Ensure auto_vacuum=INCREMENTAL applies on fresh deploys
Set only by `db/*_migrate/20260603000000_enable_incremental_vacuum.rb`, but schema
files can't carry pragmas and `db:prepare` loads schema + marks the migration
applied, so it never runs on fresh DBs. `Maintenance::RetentionJob`'s
`PRAGMA incremental_vacuum` is then a silent no-op and SQLite files only grow.
**Fix:** set `auto_vacuum` via `database.yml` config or an initializer that runs
against each connection, not a migration.

### 13. Fix DictStore caching `:missing` forever
`dict_store.rb:25` `active_id` caches the `:missing` sentinel per `(db, segment)`
via `compute_if_absent` with no TTL; only `invalidate_active` clears it, and only
in the process that ran the promotion. An ingest worker that starts before
seeding/promotion writes `dict_id`-NULL (plain-zstd) rows until restart, and never
picks up later-promoted dicts.
**Fix:** add a short TTL / periodic refresh for the `:missing` case, or a
cross-process invalidation signal.

### 14. Decide fate of removed burst/auto-ignore/ntfy alerting
This branch removed `maybe_alert_burst!`, auto-ignore, `NtfyNotifier`,
`NtfyNotificationJob`, `IssueMailer#burst_detected` with no replacement —
undocumented in commit `ecb4296` (looks like collateral of the Settings rewrite).
**Decision needed.** If intentional: drop the five orphaned settings columns the
purge migration left in `db/schema.rb` (`ntfy_url`/`ntfy_token`/`ntfy_priority`/
`auto_ignore_enabled`/`auto_ignore_threshold`) and the stale comment in
`event.rb:18`. If not: restore the burst-detection/auto-ignore path.

---

## P3 — Performance

### 15. Add composite `[transaction_name, timestamp]` index
`transactions` has only a single-column index on `transaction_name`
(`transactions_spans_schema.rb:81`). Verified via `EXPLAIN QUERY PLAN` that
per-endpoint queries (`percentiles_for_endpoint`, `time_series_for_endpoint`,
`durations_for`, `p95_by_bucket`, `histogram_percentile` raw arm) scan the
endpoint's full retention window instead of the requested time slice.
**Fix:** add a composite `[transaction_name, timestamp]` index (CLAUDE.md schema
specified it) via a new migration in `db/transactions_spans_migrate`.

### 16. Optimize percentile read path
1. `global_percentile`'s `project_id = COALESCE(?, project_id)` is non-sargable →
   full `SCAN transaction_histograms`; use conditional bind (folds into #5).
2. `percentiles` runs the heavy merge CTE 3× (once per quantile); `project.rb:93-
   101` calls it 3× more → up to 9 CTE runs per project page. Return all three
   quantiles from one query.
3. `Event#message` decompresses + parses full `payload_blob` per row in 50-row list
   views while the promoted `message` column sits unpopulated — populate/extract
   the message column or read it directly.

---

## P4 — Cleanup

### 17. Consolidate duplicated DDSketch/bucketing/upsert SQL
- `global_percentile` is a near-verbatim copy of `histogram_percentile`.
- DDSketch bucket formula `LN(MAX(duration,1))/LN(γ)` lives in 3 SQL sites
  (`transaction.rb:116`, `transaction_analytics.rb:267`, `histogram_rollup_job.rb:19`)
  + Ruby (`histogram.rb:12`) — writer/reader contract drift risk.
- `ruby_rollup` clones `bump_many!`'s upsert; the `has_ln?` fallback is dead (read
  side uses `LN()` unconditionally).
- Time-bucketing scaffold hand-rolled 6×.
- `db/seeds/compression_dictionaries.rb:17` redefines `IssuesEventsDict` instead of
  using `Compression::IssuesEventsDict`.
**Fix:** centralize the bucket formula + GAMMA, share one percentile query, extract
a bucketing helper, drop the dead fallback, use the existing dict model.

### 18. Comment purge migration as intentional wipe
Disposable-data confirmed, so
`db/migrate/20260603100000_purge_events_transactions_from_primary.rb` is correct
as-is. Add a one-line comment noting the table drops intentionally discard
pre-cutover history (no backfill by design) so a future reader doesn't mistake it
for an accidental wipe. Optional: mute `IssueMailer.new_issue` for a short window
post-deploy to avoid the one-time new-issue email burst as fingerprints repopulate.

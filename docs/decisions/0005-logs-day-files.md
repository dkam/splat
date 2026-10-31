# 0005 — Logs stored in one SQLite file per day

**Date:** 2026-10-24 (proposed, as columnar blocks), 2026-10-28 (decided, after the experiment)
**Status:** Accepted — day files. Columnar blocks for closed days are a possible
second step, measured below and deferred.
**Affects:** `LogsRecord`, `Log`, `Ingest::LogConsumer`, `LogsController`,
`EventsController`, `TransactionsController`, `ProjectTimeline`, the MCP log tools,
`Maintenance::RetentionJob`, `Maintenance::LogsFtsOptimizeJob` (removed),
`Maintenance::WalCheckpointJob`, `StorageStats`, `DatabaseBackup`,
`SqliteStatementTimeout`, `Logs::Fts`, the logs compression dictionaries,
`config/database.yml`

## Context

The logs store is one row per log in `production_logs.sqlite3`, with an
external-content FTS5 index (`logs_fts`) over `body` and `attrs_text`. At the
deep pass of 2026-10-25 it was **58.9 GB for 7.95M logs** over 15 days of
retention: 7,957 bytes per log, of which the FTS index is 41.4 GB.

Every log is stored three times:

- `body` and `attrs_text` as plain text columns, because an external-content
  FTS5 table reads its content from them;
- again inside the zstd-compressed `payload_blob`;
- again, tokenised, in the FTS index.

And the shape costs maintenance out of proportion to the feature. Most of
`docs/learnings/sqlite.md` is about this one database:

- FTS5 deletes only write delete-markers, so `LogsFtsOptimizeJob` exists, and had
  to move from `optimize` to stepped `merge` once `optimize` meant hours of held
  write lock.
- `incremental_vacuum(N)` reclaims one page per call through the Ruby driver; the
  file grew to 109 GB around 67 GB of live data before that was found.
- The WAL pins freed pages, so a vacuum loop that trusts a stalled
  `freelist_count` stops early.
- `(level)` vs `(level, timestamp)`: 34,521 ms vs 11 ms for three rows.

The common cause is retention by row delete, and the experiment below measured
what it costs: the same rows rebuilt fresh in today's layout take **2,260 bytes
per log, 3.5× less than production**. The FTS index alone is 303 bytes per log
fresh against about 5,600 in production. Some of that may be rows indexed before
attribute values were capped at 512 characters (2026-10-12); most of it is churn
the index never gives back.

## The experiment

`script/logs_day_export.rb` exported 2026-10-26 from production: 567,477 logs,
the busiest of the seven days before. `script/logs_blocks_experiment.rb` built
that day in each candidate layout and ran the same queries against each, on a
laptop NVMe. Every query returned the same rows in every arm.

- **A** — today's layout, built fresh (rows, 11 indexes, external-content FTS).
- **B** — one file for the day: today's rows without `body`/`attrs_text`, the same
  indexes, a contentless FTS5.
- **C1 / C2** — the draft's design: blocks of ~1,000 logs per stream (project,
  environment, service) with header summaries and a bloom filter. C1 packs rows
  in one zstd frame; C2 has a zstd frame per column, an attribute key per column.

The rule, fixed before the run: blocks go ahead only at a third of B's size or
less; above a half, B ships.

| Layout | Bytes/log | Times smaller than production |
|---|---:|---:|
| Production, 2026-10-25 | 7,957 | — |
| A: today's layout, fresh | 2,260 | 3.5× |
| B: day file, contentless FTS | 1,658 | 4.8× |
| C1: blocks, rows packed | 375 | 21× |
| C2: blocks, columnar | 349 | 23× |

B is 923 bytes of rows, 433 of indexes and 303 of FTS per log. The FTS is 189 at
`detail=column` and 83 at `detail=none`, though neither supports the phrase
queries `key:value` search relies on.

Queries over the one day, in milliseconds, warm / cold. The project was the
largest (67% of the day's logs, no errors that day):

| Query | B | C2 |
|---|---:|---:|
| newest 50 | 0.4 / 1.4 | 0.3 / 1.4 |
| page 5 | 0.4 / 1.8 | 0.3 / 1.2 |
| level:error newest 50 (no matches) | 97 / 3,199 | 0.3 / 19 |
| rare word | 23 / 265 | 29 / 66 |
| common word | 4.8 / 9 | 58 / 62 |
| key:value | 9.5 / 23 | 79 / 80 |
| absent word | 22 / 263 | 81 / 123 |
| duration ≥ p99.9 | 2.5 / 37 | 16 / 40 |
| trace, no time bound | 0.1 / 0.6 | 4.2 / 82 |
| log_id lookup | 0.1 / 0.7 | 3.1 / 91 |
| hourly timeline | 92 / 96 | 9 / 80 |
| decode the whole day | — | 2,943 |

Also measured:

- **Late logs are rare and short.** The largest lag from `timestamp` to
  `created_at` was 56 s, p99 5.8 s; 7 logs of the day were ingested after midnight.
- **Compacting blocks buys 18%.** Blocks sealed every 60 s of ingest average 86
  logs and 449 bytes per log, against 368 compacted.
- **Blooms are cheap**: 8 bytes per log at 12 bits per token, 0.37% false positives
  measured. A `(trace_id, block_id)` side table is 5 bytes per log.
- **Row-packed blocks are slow in Ruby.** C1 is only 7% bigger than C2, but it
  decodes whole rows for every question: 435 ms against 16 ms on the duration
  filter, 196 ms against 9 ms on the timeline.
- **Encoding is cheap**: about 110 µs per log in Ruby, under 0.1% of a core at
  this volume.

## Decision

**Logs move to one SQLite file per day, in today's row shape without the
plain-text copy.** Blocks pass the rule (C2 is 0.21 of B), but day files take 46
of the 59 GB and all of the maintenance listed above. Blocks would save about
10 GB more, at the cost of a new storage engine. That is step 2, if ever.

- **One file per UTC day of ingest**, `storage/log_days/YYYY-MM-DD.sqlite3`. Retention
  deletes files older than the window: no delete-markers, no merges, no vacuum, no
  freelist. Partitioning by ingest day, not event time, means one write target, no
  reopening a closed day for a late log, and a `log_id` (a UUIDv7, so its time is
  the ingest time) names its file. A time-range query reads one more file at its
  boundary to catch late logs, which were under a minute late on the measured day.
- **Rows keep today's columns except `attrs_text` and `updated_at`.** `attrs_text`
  exists only to feed the index, so it goes to the FTS at insert and nowhere
  else. `body` stays a column: 108 bytes per log on average, and it lets the list
  views and MCP render without decoding `payload_blob`.
- **Contentless FTS5** (`content=''`) over `body` and `attrs_text`, written by the
  consumer in the same transaction as the rows. No triggers: rows in a day file are
  never updated or deleted.
- **Fewer indexes.** With a file per day, the timestamp-led indexes cover a day,
  not 15. The set is `(project_id, timestamp)`, `(timestamp)`,
  `(project_id, level, timestamp)`, `(project_id, release, timestamp)`,
  `(trace_id)`, `(log_id)` and the partial `(project_id, duration_ms)`;
  `test/models/log_query_plan_test.rb` holds the plans each is for. The release
  index was to go too, until the built code was measured (below).
- **Each day file is a `LogsRecord` shard registered at runtime**, through
  `connection_handler.establish_connection(config, owner_name: LogsRecord, shard:)`.
  Probed on Rails 8.1: `Log`, its enum and `insert_all!` work unchanged inside
  `LogsRecord.connected_to(shard:)`, and the default database is untouched.
- **Reads run the same relation on each file, newest first, and merge.** A list
  query stops once its page is full and the next file's newest log is older than
  the page's last row. Counts sum across files. Offset paging stays.
- **The compression dictionaries move to a small catalog database**, which the
  `logs` entry in `config/database.yml` now names. Every day file's
  `payload_blob` decodes against it.
- **The current file is read, never written, until it ages out.** At cutover,
  ingest switches to day files and the old file joins reads as one more shard.
  Retention stops deleting from it and removes the whole file once its newest log
  is past the window: 15 days, no backfill, no FTS churn during the switch. Disk
  peaks at the old file plus 15 days of day files, then drops.

## As built

The 2026-10-26 export loaded through `Logs::Writer` and read back through
`Logs::Reader`, on the same laptop: **1,638 bytes per log**, with `body` kept
and the release index back. That's 1,033 of rows (`body` included), 298 of FTS,
295 of indexes and 11 of FTS docsize: about 13 GB for 15 days at 2026-10-25's
volume. Loading ran at 339 µs per log, reading the export included.

The largest project's day, 378k logs, warm / cold in milliseconds:

| Query | ms |
|---|---:|
| newest 50 | 1.2 / 36 |
| page 5 | 2.9 / 9 |
| level:error newest 50 (no matches) | 0.8 / 7 |
| release filter (no matches) | 0.8 / 16 |
| search, rare / common / absent word | 24–25 / 375–410 |
| trace count | 0.7 / 11 |
| log_id lookup | 0.3 / 9 |
| hourly timeline | 162 / 513 |
| MCP search, 24 h, every project | 131 / 1,920 |

Without `(project_id, release, timestamp)` the release filter with no matching
rows walked the whole project's day: 114 ms warm and 3.4 s cold per file, up to
16 files. The other filters on the logs page had one or two values per project
that day, each a large share of the project's logs, so a value either matched
densely or wasn't offered. Environment, service and source got no index back.

Two things the build settled that the decision above didn't:

- **`Log` loads its columns from today's day file**: the default shard has no
  logs table, so a relation built outside a file would otherwise fail to type
  its columns. A query run outside a file still fails, rather than reading
  nothing.
- **An MCP call's statement timeout covers all its files together.** Each day
  file's connection is capped at what's left of the call's 15 seconds as it's
  opened (`SqliteStatementTimeout.cover`), so sixteen files can't take sixteen
  times the cap. The cap is still per statement, so a file's two statements
  (search_text's id bounds, then the query) can each take what's left.
- **`storage/log_days/`, not `storage/logs/`**: compose.yml already mounts the
  Rails text logs at `storage/logs/{web,worker,scheduler}`.
- **A file retention deletes is let go of gently.** Another process's read
  already under way finishes on the deleted file (Linux keeps it until it's
  closed); a read that lists it just before the delete finds nothing there
  and moves on. Pools with a connection in use aren't dropped, since Rails'
  disconnect closes connections under their users.

## Step 2, deferred: columnar blocks for closed days

If disk matters later, a nightly job converts each closed day file into C2
blocks: one stream per (project, environment, service), ~1,000 logs per block,
and a header with the level mask, maximum duration, and the distinct releases,
servers, sources and loggers. Blooms at 12 bits per token, with a `trace_id` side
table. Today's file stays rows and FTS, which takes the place of the draft's
buffer table, flush job, sealed blocks and compaction. What the experiment
settled:

- **Columnar, not row-packed**, and plain msgpack-and-zstd per column; the
  per-type encodings weren't needed.
- **Ruby, not Rust.** Every query met its bar in Ruby. The weak case is a search
  the blooms can't narrow: decoding a whole day costs about 3 s, so 15 days need a
  time budget that returns partial results.
- **`trace_id` and `log_id` are `key=value` tokens**, not bare words, so free-text
  search matches what the FTS matches.

## Alternatives considered

- **Columnar blocks now, as drafted.** Passes the rule, but 10 GB of the remaining
  13 GB isn't worth a storage engine of our own yet, and every text search is
  slower than FTS.
- **Keep one file, make the FTS contentless.** Drops the plain-text copy but
  keeps retention by row delete, which is where the 18× FTS bloat and the
  maintenance jobs come from.
- **Rebuild the FTS in place once.** Reclaims most of the 41 GB, but holds the
  write lock across 8M rows, and the churn starts over.
- **VictoriaLogs as a service, DuckDB, Parquet.** As in the draft: a second
  system to run, a single-writer file format, or a scan for every text search.

## Consequences

- `LogsFtsOptimizeJob`, the logs vacuum loop and `auto_vacuum` on the logs
  database go away; the WAL checkpoint job only needs today's file.
- About 59 GB becomes about 13 GB at today's volume.
- Lookups with no time bound (`get_trace_logs`, the trace log counts on the
  event and transaction pages) visit up to 16 files: one index lookup each.
- `SqliteStatementTimeout` caps each statement, and a read across the files
  shares one deadline (see As built).
- Backups: a closed day file never changes, so it needs copying once; only
  today's file needs `.backup` or `sqlite3_rsync`. Litestream's per-file config
  can't follow files that rotate daily, and the README has to say so.
- A pasted UUID doesn't find a log whose body contains it, because `fts_query`
  collapses UUIDs and the body is indexed as typed. Day files keep that bug
  unless it's fixed alongside.

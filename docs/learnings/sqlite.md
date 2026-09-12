# SQLite

Facts about SQLite's planner and pragmas that Splat has been bitten by. Each one
names the check that proves it — re-run the check rather than trusting this file.

Splat's DBs are large (~120GB across four files as of 2026-07), so "it does a
full scan" is never a rounding error here. `EXPLAIN QUERY PLAN` is the arbiter:
**`SEARCH` is a seek, `SCAN` is not.**

## Only a *lone* MIN/MAX collapses into an index seek

`SELECT MIN(x), MAX(x) FROM t` is a full scan. Split into two statements and
each becomes an O(log n) seek. The optimisation only fires when the aggregate is
the sole aggregate in the query — with two, SQLite falls back to walking the
whole index.

```
SELECT MIN(id), MAX(id) FROM span_trees   → SCAN span_trees USING COVERING INDEX
SELECT MIN(id) FROM span_trees            → SEARCH span_trees
SELECT MAX(id) FROM span_trees            → SEARCH span_trees
```

Measured on the production `logs` table (24GB), 2026-07-17:

| Form | Time |
|---|---|
| `SELECT MIN(timestamp), MAX(timestamp) FROM logs` | **28.517s** |
| `SELECT MIN(timestamp)` + `SELECT MAX(timestamp)` as two statements | **0.004s** |

Roughly 7000×, from splitting one statement into two. This is easy to
reintroduce, because merging the two reads *looks* like an optimisation — one
round trip instead of two. It isn't. The comment on `StorageStats::DATA_SPAN`
asserted "MIN/MAX are cheap index seeks" and was wrong for months; the assertion
is what stopped anyone checking.

**Check:** `EXPLAIN QUERY PLAN SELECT MIN(x), MAX(x) FROM t`.

## `ORDER BY RANDOM() LIMIT n` reads and sorts the entire table

There's no index that helps and the limit can't be pushed into the sort, so
SQLite materialises every row, assigns each a random key, sorts, and discards
all but `n`. On a large table that's a full scan *plus* a spill-to-disk sort —
the write amplification is the tell, since a read-only query shouldn't produce
GBs of writes.

```
SELECT ... FROM span_trees ORDER BY RANDOM() LIMIT 500
  → SCAN span_trees
  → USE TEMP B-TREE FOR ORDER BY
```

To sample a large table cheaply, seek instead: take several short runs of
consecutive rows anchored at random rowids (`WHERE id >= ? ORDER BY id LIMIT k`,
which plans as `SEARCH t USING INTEGER PRIMARY KEY (rowid>?)`). Use many anchors
rather than one long run — rowid order is insertion order, so a single run only
samples one moment in time, which biases anything correlated with traffic.
Deleted rows leave holes in the rowid space, so anchor on `id >= random` and let
it walk forward to the next live row rather than expecting an exact hit.

`StorageStats.sample_rows` is the worked example: 25 anchors × 20 rows. Measured
against the production `span_trees` table (92GB, 4.4M rows), 2026-07-17: the
full 25-anchor sample, reading every sampled blob, takes **0.304s** including
process startup (`user`+`sys` 0.019s — it's almost all startup). The
`ORDER BY RANDOM()` form it replaced was a major component of an 80-minute job.

**Check:** `EXPLAIN QUERY PLAN` for `USE TEMP B-TREE`, and watch the container's
block *writes* — sorter spill shows up there, and a read-only query producing
GBs of writes is the tell.

## `DISTINCT`/`GROUP BY` have no loose index scan — they walk every entry

SQLite has no *skip scan* (a.k.a. loose index scan): to find the distinct
values of a column it reads **every** row in the scanned range and dedupes — it
cannot hop from one distinct value to the next, even when an ordered index makes
that theoretically possible. So `SELECT DISTINCT col` over a high-volume table is
O(rows), not O(distinct values), and **an index does not rescue it**.

An ordered index only removes the sort, not the walk:

```
-- col has a covering index (project_id, environment):
SELECT DISTINCT environment FROM logs WHERE project_id = 1
  → SEARCH logs USING COVERING INDEX index_logs_on_project_id_and_environment (project_id=?)
     (no temp b-tree — the index is already ordered — but still reads every
      entry in the project's slice; ~5 distinct values, ~1M reads)

-- col has no ordered index:
SELECT DISTINCT source FROM logs WHERE project_id = 1
  → SEARCH logs USING INDEX index_logs_on_project_id_and_trace_id (project_id=?)
  → USE TEMP B-TREE FOR DISTINCT   (walk every entry AND sort to dedupe)
```

Measured on the production `logs` table (~1M rows/project), 2026-07-17 —
populating the three filter dropdowns on the logs page cost **source 55.8s,
service 35.2s, environment 9.7s** (from one request's span waterfall). The
environment column was **already covered by an index and still took ~10s**,
which is the whole proof: the covering index removed the temp b-tree and nothing
else. Indexing a column you `DISTINCT` on a big table buys you almost nothing.

The fix is not a better index — it's to not `DISTINCT` the big table on the
request path at all. Maintain the small distinct set somewhere cheap (populated
at write time) and read that. See `docs/decisions/0003-facets-at-ingest.md`.

**Check:** `EXPLAIN QUERY PLAN` — a `DISTINCT`/`GROUP BY` that plans as `SEARCH`/
`SCAN` across the whole key range (with or without `USE TEMP B-TREE`) is reading
every entry. There is no `SKIP-SCAN` node in SQLite's planner; if you're hoping
for one, it isn't coming.

## A bare index on a low-cardinality column beats a timestamp range — and costs you the `LIMIT`

Given `WHERE timestamp BETWEEN ? AND ? AND level = ?` with an index on each
column separately, SQLite picks the *equality* index. It then walks every row
matching that equality across the whole table, fetches each one to test the
timestamp, and sorts the survivors in a temp B-tree. The range contributes
nothing and `LIMIT` cannot exit early, because the sort has to finish first.

```
SELECT * FROM logs
 WHERE timestamp BETWEEN ? AND ? AND level = 4
 ORDER BY timestamp DESC LIMIT 3

→ SEARCH logs USING INDEX index_logs_on_level (level=?)
  USE TEMP B-TREE FOR ORDER BY
```

**`USE TEMP B-TREE FOR ORDER BY` next to an equality-only index is the tell.**
Not the `SEARCH` — that looks healthy. The temp B-tree is what says every match
is being materialised before the limit applies, so the cost scales with how
common the value is, not with how many rows you asked for.

Measured on the production `logs` table (14.4M rows, 109GB), 2026-09-12, asking
for **three** rows from a 30-minute window:

| Index available | Time |
|---|---|
| `(level)` | **34,521ms** |
| `(level, timestamp)` | **11ms** |

The composite carries the equality *and* the ordering column, so the range and
the sort share one traversal. Two corollaries:

- **A single-column index that is a strict prefix of a composite earns nothing
  and actively costs you**, by leaving the planner a worse option to choose.
  Drop it when you add the composite.
- **Another equality column can rescue it by accident.** The same query with
  `project_id = ?` added planned against `(project_id, timestamp)` — free sort,
  no temp B-tree, fast — which made the bug look intermittent: the narrow query
  was fine, the broad one hung.

Selectivity here is a guess, not a measurement, because `ANALYZE` has never run
(below). `level = 'error'` *looks* selective and spans the entire retention
window.

**Check:** `EXPLAIN QUERY PLAN` the real query, with the real filters. Look for
`USE TEMP B-TREE FOR ORDER BY`, and for an index whose parenthesised terms omit
the range you thought was doing the work.

## `dbstat` costs a full read of the database file

`SELECT SUM(pgsize) FROM dbstat` is the only way to get true per-table byte
sizes, but it's a virtual table that walks every b-tree page. It's O(file size),
not O(tables). Treat it as a daily-at-most operation, never a request-path or
15-minute one.

For a headline "how big is this on disk", `PRAGMA page_count * PRAGMA page_size`
is two integer reads from the file header. It runs in microseconds at any size,
and reports slightly *more* than summing `dbstat` because it counts free pages
the file still occupies — which is the honest answer for disk planning.

**Check:** time it against your largest DB; if it scales with file size, it's a
page walk.

## `COUNT(*)` is a full scan — there is no row-count metadata

Unlike Postgres, SQLite keeps no row estimate to read cheaply. Every `COUNT(*)`
walks the table. Counting many tables across many DBs on a schedule adds up to a
full read of the entire dataset per pass.

**Check:** it scales with row count, always.

## `DELETE` and `DROP TABLE` never shrink the file — only `VACUUM` does

Freed pages go on the file's freelist and are reused by future writes, but the
file itself stays exactly as large as its high-water mark. Deleting 33GB of rows
returns nothing to the OS; it produces a 92GB file with 33GB of free space
inside it.

This matters for anything that reports "how big is the database":

- `PRAGMA page_count * page_size` — the **file on disk**, free pages included.
  What `df` agrees with.
- `SUM(pgsize) FROM dbstat` — **live data only**. Drops when rows are deleted.

The two diverge by exactly the freelist, and after a large deletion they can
disagree enormously. Reporting only one is misleading in opposite directions:
page_count alone hides that data was freed, dbstat alone claims disk you haven't
actually got back.

**Reusing freed pages is usually better than reclaiming them.** `VACUUM` rewrites
the entire file — hours on a large DB, an exclusive lock throughout, and it needs
free space equal to the DB's size for the temp copy. If the freed pages will be
consumed by ordinary growth soon, doing nothing is strictly better: the file just
stops growing until the freelist is used up. Only `VACUUM` when you actually need
the disk back for something else.

Note that `PRAGMA auto_vacuum` can't be turned on retroactively without a full
`VACUUM` — it has to be set before any tables are created — so it isn't an
escape hatch for an existing database.

**Check:** `PRAGMA freelist_count` (pages on the freelist), and compare
`page_count * page_size` against `SUM(pgsize) FROM dbstat`.

## `PRAGMA incremental_vacuum(N)` reclaims one page per call, whatever N is

Through the Ruby `sqlite3` driver, `incremental_vacuum(1)`, `(10)` and `(50)`
all return exactly one page to the OS — the driver steps the pragma's statement
once rather than to completion. N is close to inert; the number of **calls** is
what reclaims space.

This makes the obvious implementation silently useless. A nightly
`PRAGMA incremental_vacuum(1000)` issued once per database returns 4KB per day,
against deletes freeing several GB. Splat ran exactly that for months while the
logs file grew to 109GB around 67GB of live data.

Measured, 2026-09-12: ~1,300 calls/sec against the production logs DB, so a loop
reclaims on the order of 5MB/s. Drive the loop off `freelist_count`, not off N.

**Check:** `PRAGMA freelist_count`, one `PRAGMA incremental_vacuum(1000)`,
`PRAGMA freelist_count` again. The difference is 1.

## The WAL pins free pages — a stalled freelist does not mean the work is done

A free page whose frames are still in the WAL cannot be truncated out of the
main file. So `freelist_count` can stop falling with millions of pages still
free, and a vacuum loop that reads that as "nothing left to reclaim" stops far
too early.

`PRAGMA wal_checkpoint(PASSIVE)` is not a reliable fix: it copies frames only
until it meets an active reader, then gives up. On a continuously-read database
it frequently does nothing at all — and it is also exactly what SQLite already
does by itself at COMMIT, so calling it explicitly rarely changes the outcome.
`TRUNCATE` waits for readers (bounded by `busy_timeout`), copies every frame and
resets the WAL to zero.

Measured on the production logs DB, 2026-09-12: a vacuum loop stopped after
1,696 steps reporting nothing further reclaimable, with **7,849,972 pages
(31.6GB) still free**. Three minutes later a different job reclaimed **131,141
pages** from the same file, having done nothing but wait for a scheduled
`TRUNCATE` checkpoint. The pages were reclaimable the whole time.

**A stall is a reason to checkpoint, not a reason to stop** — but bound the
retries, because `TRUNCATE` waits on readers and is not free.

**Check:** `PRAGMA freelist_count`, then `PRAGMA wal_checkpoint(TRUNCATE)`, then
`PRAGMA freelist_count` again. A drop means the WAL was the constraint.

## `CREATE INDEX` builds out of the freelist, and its sort phase writes nothing to the WAL

Two consequences, both of which look alarming and aren't.

**The file does not grow** if the freelist can cover the new index. Building two
indexes totalling ~977MB on a 14.4M-row table left `page_count` unchanged at
26,643,126 and the file byte-identical at 109,130,244,096 — the accumulated
bloat paid for the index. Corollary: the freelist shrinking is not always the
vacuum working.

**A motionless WAL means sorting, not stalling.** `CREATE INDEX` runs an
external merge sort first, spilling to temp files that are unlinked immediately
(so `/tmp` looks empty), and only writes the finished b-tree into the WAL in one
burst at the end. On a large table that is many minutes of a completely static
WAL, with the process parked in uninterruptible disk sleep — which is easily
mistaken for a deadlock. Measured: ~9–13 minutes per index at ~44MB/s of
sustained reads over a 33GB table.

**Check:** `/proc/<pid>/io`. Climbing `read_bytes` with state `D` means it is
working; flat `read_bytes` with state `S` and no CPU accumulating means it is
genuinely blocked on a lock.

## Production has never had `ANALYZE` run

As of 2026-07-17, `sqlite_stat1` does not exist in the production DBs, so the
planner works with no statistics at all. Two consequences:

- Plans verified against a small dev DB do generalise, since both are
  stats-blind. That's luck, not design — don't rely on it once `ANALYZE` runs
  somewhere but not everywhere.
- Any query whose plan depends on selectivity estimates is being planned blind.
  The seeks documented above are structural (rowid/index order) so they're
  unaffected, but this is worth revisiting for the app's real query paths.

**Check:** `SELECT COUNT(*) FROM sqlite_master WHERE name = 'sqlite_stat1'`.

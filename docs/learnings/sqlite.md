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

# Splat docs

Four kinds of document, separated by how fast they go stale. That separation is
the whole point: `docs/` previously accumulated seven files, six of which rotted
within months, because audits and backlogs are wrong the moment you fix
something and nobody goes back to prune them. See `archive/`.

## Where does this note go?

Ask in order; the first match wins.

**Is it about *our* code?** → Write a code comment, not a doc. Splat's inline
comments carry the *why* (see `app/models/storage_stats.rb`), and a doc that
restates them goes stale while the code moves on. A doc can't be code-reviewed
against the thing it describes; a comment can.

**Is it a fact about a *tool* — SQLite, tuber, the Sentry protocol — that would
still be true on a different project?** → `learnings/`, one file per tool.
"SQLite only optimises a lone `MIN(x)` into a seek" is true forever and
everywhere. These don't rot, which is what earns them a file.

**Is it a choice we made, with alternatives we rejected?** → `decisions/`, dated
and numbered. An ADR can't go stale, because it's a record of what we knew *at
the time*. If a later decision reverses it, write a new ADR and link back —
never edit the old one.

When an ADR turns out to have been **wrong about a fact** (as opposed to
reversed by a later decision), append a dated `## Amendment` section to it rather
than editing the body. Quietly correcting the body destroys the useful part —
the record of what we believed and therefore what we missed. The amendment sits
next to the claim it corrects, which is where a reader will actually look.

**Is it an external spec we didn't write?** → `reference/`.

**Is it a task?** → The issue tracker. Not here. This is precisely what killed
`improvements.md` (686 lines) and `issues.md`.

## Layout

| Path | What | Decay |
|---|---|---|
| `learnings/` | Durable facts about tools we depend on | None — restate as facts, not as "we changed X" |
| `decisions/` | Numbered, dated ADRs. Append-only | None — explicitly historical |
| `reference/` | External specs (Sentry envelope format) | Tracks upstream |
| `archive/` | Superseded docs, kept readable but marked dead | Already dead |

## Index

**Learnings**

- [`learnings/sqlite.md`](learnings/sqlite.md) — planner and pragma facts, with
  measured prod numbers. Lone `MIN`/`MAX` seeks (28.5s → 0.004s), why
  `ORDER BY RANDOM()` can't be limited, no loose index scan so `DISTINCT` walks
  every entry (a covered column still took 9.7s), `dbstat`/`COUNT(*)` costs, why
  `DELETE` never shrinks a file, and the fact that `ANALYZE` has never run on prod.
- [`learnings/tuber.md`](learnings/tuber.md) — `idp:` only dedupes while a job is
  *queued*, reading `stats-tube` to spot a starved tube, single-threaded
  consumers, job body shape.

**Reference**

- [`reference/sentry-payload.md`](reference/sentry-payload.md) — what actually
  arrives at the ingest endpoint and what Splat does with it: the envelope wire
  format, item-type routing, the event payload's 21 keys, stack frame anatomy,
  and which nine fields become columns. Drawn from real payloads.
- [`reference/envelopes.md`](reference/envelopes.md) — the full upstream Sentry
  envelope spec.

**Decisions**

- [`decisions/0001-storage-stats-cadence.md`](decisions/0001-storage-stats-cadence.md)
  — split the storage scan into a cheap hourly pass and a deep daily one, after
  the 15-minute version grew to 80 minutes and permanently occupied the
  maintenance worker.
- [`decisions/0002-legacy-spans-drop.md`](decisions/0002-legacy-spans-drop.md) —
  drop the frozen `spans` table (33GB, 36% of the transactions DB) once retention
  empties it ~2026-07-28, and deliberately don't VACUUM afterwards. **Has a
  checklist with a pending action.**
- [`decisions/0003-facets-at-ingest.md`](decisions/0003-facets-at-ingest.md) —
  maintain the filter-dropdown values (log/transaction environment, source,
  service) in a `facets` table populated at ingest, after `DISTINCT` scans made
  the logs page take ~100s. Why an index didn't fix it and the cache only hid it.
- [`decisions/0004-file-driven-releases.md`](decisions/0004-file-driven-releases.md)
  — bumping `config/version.rb` on main *is* the release, and CI creates the git
  tag as a consequence. Written after the constant reached 1.14.0 while the
  newest tag was still v1.7.8. Also: version vs. revision, and why a boot-time
  guard must not fire during `assets:precompile`.

## Conventions

- **Learnings are facts, not news.** Write "SQLite plans `MIN(x), MAX(x)` as a
  SCAN" — not "we fixed the storage stats job". The second is a changelog entry
  and git already has it.
- **Every learning states how to verify it.** A claim you can't re-check is a
  claim that quietly becomes false. `EXPLAIN QUERY PLAN`, a `docker stats`
  reading, a benchmark — name the check.
- **ADRs are `NNNN-kebab-title.md`**, numbered in order, never renumbered.
- **Archiving beats deleting** when a doc shaped a decision someone might dig
  up. Add a `> **SUPERSEDED**` banner at the top saying what replaced it and
  when. `duckdb_migration_guide.md` is the cautionary tale — it stayed live for
  eight months describing a job that no longer exists.

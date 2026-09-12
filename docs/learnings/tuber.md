# Tuber

Behaviours of the tuber queue that Splat depends on. Inspect a live server with
`tuber-cli -a <host>:11330 stats-tube <tube>` (JSON by default).

## `idp:` suppresses a duplicate put while the job is in the tube — in *any* state

The idempotency key stops a duplicate put while a job carrying that key exists
in the tube. Measured against production tuber, 2026-09-12, putting the same key
four times and inspecting the state the server echoes back:

| Existing job's state | Duplicate put |
|---|---|
| `READY` | dropped |
| `RESERVED` | **dropped** |
| `BURIED` | **dropped** |

Four puts, one job in the tube at the end (`ready=0 reserved=0 buried=1`). The
response echoes the existing job's id and state rather than inserting.

**This file previously claimed the key is released once a worker reserves the
job.** That is not what tuber does today — `RESERVED` dedupes exactly like
`READY`. The claim was written from `Maintenance::StorageStatsJob` stacking to
three ready copies on a 15-minute cron (see
`docs/decisions/0001-storage-stats-cadence.md`); given the measurement above,
that stacking needs another explanation — TTR auto-release (below) is the
obvious candidate, since it returns a still-running job to `ready` without any
put being involved. Re-run the check before relying on either reading.

**Check:** put a key into a scratch tube, reserve it on a second connection, put
the same key again, bury it, put again. Compare `current_jobs_*` in `stats-tube`
against the number of puts. Reserve and bury must share one connection — a
reservation dies with the connection that holds it, so one-shot CLI calls will
release the job between commands and silently test the wrong thing.

## A buried job holds its `idp:` key forever, which stops the schedule silently

Dedupe while `READY` or `RESERVED` is bounded — the job finishes and the key
frees. Burying has no such bound: a buried job sits in the tube holding its key
until a human kicks or deletes it, so every subsequent put with that key is
dropped. For a recurring job the schedule stops dead — not delayed, not stacked,
just gone, with no error after the one that caused the bury.

**The tube reads as healthy while this happens.** `current_jobs_ready` and
`current_jobs_reserved` are both 0 — which is exactly what an idle, working tube
looks like. The only field that says otherwise is `current_jobs_buried`.

Splat lost ~70 hourly rollups over three days this way, 2026-09-09 to 09-12:
`Analytics::HistogramRollupJob` hit a `SQLite3::BusyException` behind a
long-running retention pass, exhausted its retries, buried, and thereby
suppressed every hourly put that followed. Nothing alerted, because queue depth
was zero the entire time.

Two consequences worth designing around:

- **On an `idp:` tube, a bury is an outage, not a backlog.** A consumer should
  tolerate expected transient failures (lock contention, a busy database) rather
  than let them reach the retry ceiling. Burying is correct for a poison-pill
  body and wrong for a busy database.
- **Monitor `current_jobs_buried`, not just depth.** Depth cannot express this
  failure; it reports the healthy value.

**Check:** `stats-tube` → `current_jobs_buried` and `total_buries`. `peek-buried`
shows the body, `kick-job <id>` returns one job to ready.

## TTR is a dead-worker timer, not a job-duration budget

At TTR the server auto-releases the job back to ready. This happens **server-side,
silently** — the consumer is still executing and never learns its reservation is
gone. It finds out, if at all, when its `delete` at the end lands on a job it no
longer holds.

So a job that outruns its TTR doesn't fail loudly. It produces a job that is
simultaneously "ready" on the tube and "running" in a worker, and the auto-release
increments the job's `releases` counter, which is the same counter retry logic
reads.

**`reserve_batch(n)` makes this much worse than it looks.** All *n* jobs are
reserved at once and their TTR clocks all start together, but they're processed
serially. The effective budget is therefore `TTR ÷ n` per job, not `TTR`. Splat
reserves 100 at a time.

**Prefer `touch` over a bigger TTR.** `touch` resets a reserved job's TTR; the
idiom is a heartbeat on an interval well inside TTR, for as long as the handler
runs. Raising TTR to cover the slowest job instead:

- trades away the only thing TTR does — a crashed worker's job now sits invisible
  for the new, longer TTR;
- is a bet on runtime that data growth eventually breaks (the reason the number
  was wrong the first time);
- **still doesn't work with batch reserve**, since you'd need `TTR × batch_size`.

A heartbeat must touch **every job in the reserved batch**, not just the one
executing — the other *n-1* are bleeding TTR in the background. `DEADLINE_SOON`
is the server telling a worker one of its reserved jobs is about to expire.

**Check:** `total_timeouts` in `stats-tube` — any nonzero value on a tube whose
handlers are supposed to be fast means something is overshooting. Compare the
tube's `processing_time_p95` against the TTR the producer used.

## Reading tube stats: how to tell a busy worker from an idle one

`stats-tube` distinguishes these clearly, and it's the fastest way to find a
starved tube:

- **`current_waiting: 1`** — a worker is parked on a reserve. The tube is idle
  and healthy.
- **`current_waiting: 0` with `current_jobs_ready > 0`** — jobs are queued and
  nobody is coming for them. The worker exists but is busy elsewhere.
- **`oldest_ready_age`** — seconds the front job has waited. The honest backlog
  number.
- **`queue_time_ewma`** — average wait before pickup. A value in the thousands
  means the tube is minutes-to-hours behind, regardless of how healthy
  `processing_time_*` looks.

A worker that shows `current_waiting: 0` on one tube while every other tube on
the same worker shows `current_waiting: 1` is the signature of a single job
monopolising a single-threaded consumer.

## Consumers are single-threaded per worker

`Ingest::DispatchConsumer` drains a tube by calling `#perform(*args)` inline, one
job at a time. Anything slow on a maintenance tube starves *every* other job on
that tube — recurring rollups included. Check what else shares the tube in
`config/schedule.yml` before accepting a long-running job on it.

## Job bodies are `{"class": ..., "args": [...]}`

`Ingest::Scheduler` reads `config/schedule.yml` and puts this shape; the consumer
splats `args` into `perform`. One class can be scheduled at several cadences
with different args — give each entry its own `idp:` key, or they suppress each
other.

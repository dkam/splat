# Tuber

Behaviours of the tuber queue that Splat depends on. Inspect a live server with
`tuber-cli -a <host>:11330 stats-tube <tube>` (JSON by default).

## `idp:` only suppresses puts while the job is *queued*, not while it runs

The idempotency key stops a duplicate put when a job with the same key is
already in the tube. Once a worker reserves the job, the key is free again — so
a cron job that runs longer than its interval **will** stack up: each tick puts
a fresh copy while the previous one is still executing.

`idp:` therefore protects against a *put* flood, not against a slow job. If a
job can outlive its schedule, the fix is to make the job faster or the schedule
slower. It is not a substitute for either.

Splat learned this from `Maintenance::StorageStatsJob` on a 15-minute cron: once
a pass took ~80 minutes, three copies sat ready at all times, and the comment in
`schedule.yml` claiming idp "guards against stacking" was wrong. See
`docs/decisions/0001-storage-stats-cadence.md`.

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

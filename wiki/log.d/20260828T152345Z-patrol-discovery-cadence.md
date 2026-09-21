# 2026-08-28 — Decouple Patrol discovery from scheduler snapshots

## Summary

Moved project-level Patrol discovery onto one background worker so a slow
repository scan cannot hold the daemon's authoritative task snapshot past its
validity deadline.

## Details

- The full daemon tick publishes its active task reconciliation before polling
  Patrol discovery.
- At most one discovery pass runs. A later tick keeps publishing scheduler
  state without waiting for or overlapping that pass.
- A completed candidate batch is harvested on a later tick. Reservation,
  capacity and configuration gates, process spawn, and arbiter commit remain on
  the dispatcher thread.
- Ordinary Patrol reservation now rechecks live registration, enablement,
  capacity, and failure backoff. Architecture reservation also rejects
  registration replacement, and claim acquisition now enforces the latest
  durable retry deadline.
- Architecture discovery maintenance retains its store locks; diagnostic
  writes additionally compare the job version observed before the worker acts,
  so a stale ownership decision cannot overwrite newer completion state.
- A pass lasting three poll intervals emits one warning. A worker still alive
  after the bounded shutdown join keeps the shutdown receipt non-drained.
- Focused tests block discovery deliberately and prove fresh repeated scheduler
  publication, non-overlap, later harvest, stale-candidate fences, worker-error
  recovery, stall deduplication, and truthful shutdown state.

## Refreshed pages

- [[modules/daemon]]
- [[testing]]
- [[gaps]]

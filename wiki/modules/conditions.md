---
title: Generation-scoped task conditions
type: module
source: lib/hive/conditions/, lib/hive/task_journal.rb, lib/hive/task_projection.rb
created: 2026-07-17
updated: 2026-07-17
tags: [conditions, projection, journal, execute, migration]
---

**TLDR**: Execute completion can be evaluated from versioned, generation-
scoped condition facts in the task's durable journal. A pure projection selects
the current task epoch, durable attempt family, and exact HEAD revision;
markers remain dual-written for compatibility and rollback.

## Vocabulary and scopes

The registry knows seven conditions. Increment 1 makes `AgentHealthy`,
`ChangesPresent`, and the `AwaitingHuman` inhibitor authoritative-capable only
for `4-execute`. `BranchPushed`, `ArtifactCurrent`, `BabysitterActive`, and
`Merged` are registered vocabulary for later rollout and do not gate their
stages yet. Observations use `pending`, `satisfied`, `unsatisfied`, or
`unverifiable`; the projector alone adds `superseded` history.

Every condition observation has a durable attempt ID, numeric task input
epoch, optional commit generation, explicit reason/time, typed evidence, and
provenance. The numeric epoch is distinct from the opaque attempt ownership
generation. Retry/adoption preserves the input epoch; accepted input changes,
operator decisions, fenced repairs, and workflow invalidations advance it.
Commit generation advances only when the exact observed HEAD changes.

## Write and read paths

`Hive::TaskJournal::Writer` appends authoritative batches under a task-local
flock, writes complete JSON lines, flushes/fsyncs, and surfaces failure. Legacy
`Hive::Events.emit` remains fail-soft telemetry and refuses authoritative event
types. At an execute boundary the order is reconciliation, durable batch,
snapshot publication, gate evaluation, compatibility marker.

`Hive::TaskProjection` is a pure journal fold. It performs no git, GitHub, or
subprocess observation. The atomic `task-projection.json` stores journal
cursor/event/hash, identity, current/history conditions, evidence, default
gate diagnostics, provenance, compatibility, and shadow audit. A read accepts
the snapshot only when its binding validates; otherwise it replays in memory.
Only mutating reconciliation republishes it.

Selection proceeds by current task generation, then latest compatible attempt
within each registry family, then exact commit generation/HEAD for branch facts.
Displaced facts stay in history. Required conditions pass only when satisfied.
`AwaitingHuman=satisfied` blocks its named transition; an answered or
superseding observation removes it from current gates.

## Authority migration

Project config accepts `markers`, `shadow`, or `conditions`; only a
`4-execute` override can select condition authority in increment 1. A legacy
task remains marker-authoritative until a real supervised attempt exists.
Shadow mode follows marker action and appends structured comparisons. Readiness
needs 100 transitions, all five scenario categories, zero unexplained drift,
an empty allow-list, and green golden fixtures. No code auto-promotes config.

See [the operator runbook](../../docs/condition-rollout.md) for repair,
promotion, and rollback and `test/fixtures/incidents/task-1849/` for the
sanitized stale-wait golden replay.

## Backlinks

- [[state-model]] · [[modules/events]] · [[modules/attempts]]
- [[modules/task_action]] · [[commands/status]] · [[stages/execute]]

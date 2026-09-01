---
title: Generation-scoped task conditions
type: module
source: lib/hive/conditions/, lib/hive/task_journal.rb, lib/hive/task_projection.rb, lib/hive/task_projection/reader.rb
created: 2026-07-17
updated: 2026-09-01
tags: [conditions, projection, journal, execute, migration, bounded-storage]
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

Transition membership has exactly one internal representation: the gate
rules registered in `Conditions::Policy.default`. The registry owns only
condition semantics (family, supersession family, scope, allowed evidence,
gate role, authoritative stages) and carries no condition-to-transition
membership; `Definition` exposes no `default_transitions` field. Policy
descriptors are validated against registered vocabulary, so an unknown or
wrong-role condition in a gate rule raises `InvalidPolicy`.

Every condition observation has a durable attempt ID, numeric task input
epoch, optional commit generation, explicit reason/time, typed evidence, and
provenance. The numeric epoch is distinct from the opaque attempt ownership
generation. Retry/adoption preserves the input epoch; accepted input changes,
operator decisions, fenced repairs, and workflow invalidations advance it.
Commit generation advances only when the exact observed HEAD changes.

## Write and read paths

`Hive::TaskJournal::Writer` appends authoritative batches under an exclusive
task-local flock to `<task>/task-journal.jsonl`, retries short writes,
flushes/fsyncs, and restores the previous byte boundary if a write fails. New
events validate their task, stage, numeric input epoch, opaque ownership
generation, and durable attempt before append. Legacy `Hive::Events.emit`
remains separate fail-soft telemetry in `<task>/events.jsonl`.

`Hive::TaskProjection::Reader` is a direct bounded reader, not a store. It
takes a shared lock, validates complete JSON lines, the hash chain, one task /
workflow stream, and stable attempt bindings, then folds them in memory through
`Hive::TaskProjection`. Routine scheduling reads cover the complete journal;
only task-workspace presentation applies the 1 MiB / 2,000-event limits.
Historical replay is self-contained: it performs no SQLite, git, GitHub, or
subprocess lookup. The fold derives retry lineage from journal provenance, so
causal order wins over wall-clock regression.

A missing journal is an empty history stream. Invalid, partial,
over-limit workspace history or lock-unsafe history yields a synthetic
`condition_task_history_invalid` row for that task; unrelated work continues.
There is no snapshot, checkpoint, repair command, repair queue, or background
projection watcher. Restore or correct the authoritative JSONL itself.

Execute-observation deduplication compares a fresh observation with the latest
record in the same stream (`event_type` + attempt + condition). A state that
changes away and later returns must append again; only an unchanged repeat of
the current value is skipped. At an execute boundary the order is
reconciliation, journal append, in-memory fold, gate evaluation, and
compatibility marker.

Selection proceeds by numeric task epoch, then compatible attempt lineage,
then exact commit generation for branch facts. Current `AgentHealthy` also
reconciles terminal/lost SQLite attempt state before its journal observation is
appended. Successful terminal attempts satisfy the condition; ordinary
failed/cancelled/lost attempts fail closed. Exit 75 remains pending because it
is scheduler contention rather than an agent verdict.
Displaced facts stay in history. Required conditions pass only when satisfied.
`AwaitingHuman=satisfied` blocks its named transition; an answered or
superseding observation removes it from current gates.

A terminal or lost attempt that still owes its journal publication temporarily
fences the transition. Once that idempotent append is acknowledged, the JSONL
fact alone decides the gate; SQLite never becomes a parallel historical
authority.

Condition failures produce one `RecoveryAction` across status and run/approve/
workflow-verb error envelopes. Explicit forced overrides append an idempotent
`operator_action` before mutation; append/rebuild failures fail closed. The
projection exposes the latest 20 as `condition_overrides` for agent inspection,
while the authoritative journal retains the full audit.

## Authority migration

Project config accepts `markers`, `shadow`, or `conditions`; only a
`4-execute` override can select condition authority in increment 1. A legacy
task remains marker-authoritative until a real supervised attempt exists.
Shadow mode follows marker action and appends structured comparisons. Readiness
needs 100 distinct transitions, all five scenario categories, zero unexplained
drift, an empty allow-list, and green golden fixtures. Re-evaluating the same
attempt/generation/category/action tuple is deduplicated. The status projection
can report `parity_ready`, but full `ready` stays false until the operator's
external golden-fixture result is supplied. No code auto-promotes config.

See [the operator runbook](../../docs/condition-rollout.md) for repair,
promotion, and rollback and `test/fixtures/incidents/task-1849/` for the
sanitized stale-wait golden replay.

## Backlinks

- [[state-model]] · [[modules/events]] · [[modules/attempts]]
- [[modules/task_action]] · [[commands/status]] · [[stages/execute]]

---
title: Generation-scoped task conditions
type: module
source: lib/hive/conditions/, lib/hive/task_journal.rb, lib/hive/task_projection.rb, lib/hive/task_projection/store.rb
created: 2026-07-17
updated: 2026-08-29
tags: [conditions, projection, journal, execute, migration, bounded-storage, repair]
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
flock to `<task>/task-journal.jsonl`, retries short writes, flushes/fsyncs, and
restores the previous durable byte boundary if any write or sync step fails.
First creation (including a retry over an empty file left by a failed first
append) also fsyncs the task directory.
The shared journal validator
checks record shape, the exact supported schema version, and the task/stage/
input-epoch/ownership identity against the durable attempt store on both write
and projection replay. It walks the immutable predecessor chain, rejecting
missing links, incompatible identity, and cycles. Legacy `Hive::Events.emit` remains fail-soft telemetry
in the separate `<task>/events.jsonl` file and refuses authoritative event
types. At an execute boundary the order is
reconciliation, durable batch, snapshot publication, gate evaluation,
compatibility marker.

Execute-observation deduplication in the reconciler compares each fresh
observation only against the most recent journal record of the same event
stream (`event_type` + `attempt_id` + condition name), never against the whole
history. Journal consumers apply last-event-wins semantics, so a re-transition
back to a previously observed state (for example a worktree becoming dirty
again at an unchanged HEAD) must append a new record even though an identical
older one exists; only an unchanged re-observation of the latest stream state
is skipped.

Journal envelopes, idempotent journal appends, condition evidence, policy
descriptors/options, execute-observation deduplication, and task-projection
copies all normalize nested hash keys through `Hive::StringifyKeys`. The
transform recurses through arrays, leaves scalar values unchanged, and returns
new containers, so these durable surfaces cannot drift between shallow and
deep symbol-key handling.

`Hive::TaskProjection` is a pure journal fold. It performs no git, GitHub, or
subprocess observation. The atomic `task-projection.json` stores journal
cursor/event/hash, identity, current/history conditions, evidence, default
gate diagnostics, provenance, compatibility, and shadow audit. A read accepts
the snapshot only when its cursor/hash binding and every unique current or
predecessor attempt binding still validate; otherwise it fully parses/replays
the journal or fails closed. A missing/zero-byte journal after a snapshot or
attempt-stamped `execute_*` marker proves durable condition handoff is invalid
on read and rebuild, and rebuild cannot overwrite the last snapshot. Markers
from non-execute stages do not claim this execute-journal handoff. Only
mutating reconciliation republishes it.

Routine task-graph scans use the separately bounded
`task-projection.checkpoint.json` as a strict read model. One scan-wide attempt
projection reader is reused; each task may validate a 512 KiB checkpoint, a
1 MiB / 2,000-event append-only suffix, 100 attempt IDs, and 32 predecessor
point fetches. The reader refreshes referenced mutable attempt bindings and
reprojects only the bounded suffix. It never falls back to the complete
journal, invokes `rebuild!`, or enumerates permanent proof storage.
Operational-action token revalidation and downstream attempt-generation reads
use the same strict reader; they surface repair-required state instead of
guessing that an absent journal means a pristine task.
Routine reads take the task-local journal lock with a nonblocking shared flock
after regular-file, no-follow, and descriptor-identity checks. A concurrent
exact repair or unsafe lock entry becomes the transient task-local
`journal_lock_busy` diagnostic rather than stalling the fleet scan.

Canonical task creation publishes a zero-history snapshot and checkpoint before
the task is committed or admitted. The checkpoint is valid without creating an
empty authoritative journal, then moves with the task and accepts bounded
journal suffixes when execution starts. This keeps newly created tasks on the
strict path from their first scan. It is creation-time derived-state
initialization, not migration or repair of an existing task.

A task with durable history and a missing, invalid, stale, torn, oversized, or
otherwise unverifiable bounded projection becomes a synthetic
`condition_projection_repair_required` row. The row is operator-owned and
recomputed rather than persisted; unrelated tasks continue. Only the complete
initial-stage zero-state may project as pristine without a checkpoint. The
explicit [[commands/repair-projection]] command owns full replay for one exact
task. It changes derived snapshot/checkpoint files only; it is neither a
workflow retry nor a migration or watcher. The repair command may also restore
missing derived files for a journal-less task only when the same shared
creation-state predicate proves the canonical initial zero-history state.

Selection proceeds by current task generation, then latest compatible attempt
within each registry family, then exact commit generation/HEAD for branch facts.
Predecessor lineage outranks wall-clock timestamps, so a clock step backward
cannot let an older lost attempt supersede its successful successor. Current
`AgentHealthy` also reconciles directly from terminal/lost durable attempt
state, closing the window before the daemon observer appends its lifecycle fact.
Successful terminal attempts are satisfied and ordinary failed/cancelled/lost
attempts fail closed. A terminal exit `75 (TEMPFAIL)` is instead pending with
reason `attempt_terminal_retryable`: the scheduler owns that transient retry,
so lock contention cannot be projected as an agent-health failure.
Displaced facts stay in history. Required conditions pass only when satisfied.
`AwaitingHuman=satisfied` blocks its named transition; an answered or
superseding observation removes it from current gates.

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

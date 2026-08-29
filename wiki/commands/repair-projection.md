---
title: hive repair-projection
type: command
source: lib/hive/commands/repair_projection.rb, lib/hive/task_projection/store.rb, schemas/hive-repair-projection.v1.json
created: 2026-08-29
updated: 2026-08-30
tags: [command, repair, projection, status, conditions, bounded-storage, operator]
---

**TLDR**: `hive repair-projection` explicitly rebuilds the derived condition
projection for one exact registered task. Use only the fully scoped command
reported by a `condition_projection_repair_required` status row. It is not a
workflow retry, migration, fleet operation, or daemon watcher.

## Usage

```bash
hive repair-projection TARGET [--project NAME] [--stage STAGE] [--json]
```

Prefer the exact status-provided form:

```bash
hive repair-projection TASK-SLUG --project PROJECT --stage 4-execute
```

The command resolves one task in the registered project set, takes its existing
task lock, resolves it again under that lock, and excludes concurrent journal
appends while rebuilding. It reads that task's complete authoritative journal
and only the exact attempt proofs referenced by it; it does not enumerate the
proof root or inspect other tasks.

The journal, attempt proofs, marker, stage, and worktree remain authority and
are not changed. Repair atomically replaces each derived file—
`task-projection.json` and `task-projection.checkpoint.json`—then accepts
success only when the same strict bounded reader used by routine status proves
the checkpoint current. An interruption can leave one complete derived file
newer than the other, but the next scan still fails closed as repair-required.
For a task that still proves the canonical initial zero-history state, repair
may republish those two derived files without creating an authoritative
journal. The same shared pristine predicate used by status must prove that
exception; an arbitrary journal-less task is still rejected.

On success, human output names the task and journal cursor; `--json` emits
`hive-repair-projection.v1` with `outcome: repaired` and the next action
`hive status --operational --json`. The daemon does not need a restart: its
next scan recomputes the row from the repaired checkpoint.

## Failures and ownership

Ambiguous or moved targets, an existing live task lock, corrupt journal bytes,
or unavailable referenced proof return typed failures without changing
authority. A non-terminal postcondition failure returns the same exact repair
command only when retry can plausibly succeed.

These bounded reasons are terminal under the current limits:

- `checkpoint_oversized`
- `attempt_ids_exhausted`

For those rows, repeating repair cannot make the projection fit. Compact that
single task's retained projection history before repairing again; Hive does not
raise the limits, create a migration, or run periodic repair machinery.
`predecessor_fetches_exhausted` is repairable because exact replay can move the
validated history behind a fresh checkpoint.

Ordinary `ERROR` and `REVIEW_ERROR` recovery is separate. A guarded
`workflow.retry` reruns the owning workflow stage; it cannot rebuild a missing,
invalid, or unverifiable projection checkpoint. Synthetic projection-repair
rows are operator-owned and excluded from automatic retry, healing, merge
closure, provider admission, and Patrol Fix admission. Unrelated tasks continue
through the daemon, while a real live lock on the degraded task still reserves
capacity.

## Backlinks

- [[commands/status]]
- [[modules/conditions]]
- [[modules/attempts]]
- [[modules/daemon]]

---
title: Fold task history directly from JSONL
date: 2026-09-01
tags: [task-journal, status, attempts, simplification]
---

- Made `task-journal.jsonl` the sole persistent task-history authority. Status,
  task detail, closure, recovery, and generation checks now take a shared lock
  and fold the bounded journal directly in memory.
- Removed `task-projection.json`, `task-projection.checkpoint.json`, the
  projection repair command/schema, checkpoint refresh/repair paths, and
  SQLite-dependent historical replay. Invalid history now fails only its task
  closed as `condition_task_history_invalid`.
- Simplified durable attempts around one configured dispatcher shared by
  foreground and daemon admission, one `Repository#active_attempts` query, and
  one reconciliation record set. Removed the scan wrapper, output-reference
  compatibility namespace, legacy opaque context-generation bridge, redundant
  handoff/result plumbing, and unused recovery lookups. SQLite remains the
  authority for live attempts, leases, dispatch, accounting, and receipts.
- Treat an absent journal as an empty stream, while malformed or truncated
  JSONL remains invalid. A live admitted attempt with missing history still
  blocks its condition transition using the SQLite live-attempt authority.
  A busy writer makes bounded scans return immediately as transient
  scheduler-owned unavailability rather than stalling the fleet or reporting
  corruption.
- Kept routine scheduler folds complete while limiting only task-workspace
  presentation, bound each journal to its containing task/workflow and each
  attempt to one generation identity, and recheck a newly appeared lock
  sidecar so the first append cannot be read unlocked.
- Fence transitions while a terminal/lost attempt still owes its idempotent
  journal publication. After acknowledgement the JSONL fact is again the only
  history authority.
- Seed task detail from every non-legacy attempt ID named by the bounded
  journal, preserving independent manual retries and their SQLite token-usage
  sessions without a global attempt scan.

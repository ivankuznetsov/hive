# Bound routine status to task-local projection state

Routine task-graph scans now validate one bounded checkpoint and journal suffix
per task, reuse one scan-wide attempt projection reader, and never fall back to
complete-journal replay or permanent-proof enumeration. A projection that
cannot be verified becomes a synthetic operator-owned repair row; the daemon
skips only that task and continues unrelated workflow and Patrol Fix work.

Operators repair a repairable row with its exact
`hive repair-projection TASK --project PROJECT --stage STAGE` command. The
command rebuilds only derived state for that task and verifies the strict
bounded postcondition. Workflow retry, storage migration, daemon restart, and
periodic repair watchers are not substitutes. Checkpoint size and attempt-ID
cap exhaustion require task-local retained-history compaction;
predecessor-fetch exhaustion remains exact-task repairable.

Canonical initial-stage CLI, idempotent/controller, and Patrol Fix task
creation now publish a zero-history derived checkpoint before exposing the
task. Direct-to-review ad-hoc tasks instead publish a generation-0 authoritative
baseline and derive their checkpoint from it. The initial-stage initializer
refuses pre-existing projection authority, so it closes the new-task gap
without becoming an implicit repair or migration path.

Operational-action freshness checks and downstream generation reads now use
the strict projection path too. Bounded suffix preflight parses attempt IDs and
event counts once, while PR merge reconciliation reuses one attempt projection
reader across all selected projects in a tick. Routine journal locks are
nonblocking: contention is transient, while unsafe lock entries are durable
task-local repair failures. Repair
classification is a producer-owned status field, not an agent-writable marker
claim, and merge candidates survive temporary projection outages.

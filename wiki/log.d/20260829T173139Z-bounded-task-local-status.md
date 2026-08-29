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
periodic repair watchers are not substitutes. Checkpoint size, attempt-ID, and
predecessor-fetch cap exhaustion instead require task-local retained-history
compaction before another repair.

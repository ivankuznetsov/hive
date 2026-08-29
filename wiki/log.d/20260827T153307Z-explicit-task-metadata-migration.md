## [2026-08-27T15:33:07Z] migration — Remove runtime task metadata backfillers

**Action:** Removed daemon-time task-id and display-name backfillers plus the status-time archived completion-clock backfiller. `hive migrate` is now the sole legacy task-metadata migration boundary: it already owns id and display-name repair and now discovers and commits missing archived `completed_at` values explicitly. Discovery stays outside the commit lock; the locked phase revalidates candidates, commits exact metadata paths, and rolls back on commit failure. Ordinary daemon ticks, incremental ticks, status refreshes, `run`, and `approve` no longer discover or persist legacy metadata. Recovery receipts direct id-less tasks to `hive migrate --all`, and an ordinary run never stamps a legacy task that was already archived.

**Why:** Routine scheduler and status work was taking the same project commit lock as stage transitions. On a large Patrol backlog that created avoidable contention, malformed partial sidecars, and migration cost proportional to every refresh. The explicit command makes cutover finite and keeps runtime projection read-only.

**Tests:** Added migrate integration coverage for archived completion clocks,
idempotent reruns, malformed-task isolation, exact-path commits, and
commit-failure rollback. Added an observable daemon-tick
test proving missing task metadata remains unchanged and finite-retention
archive coverage proving missing clocks remain visible. Recovery tests pin the
explicit migration remediation, and run tests pin the current-transition-only
completion stamp. Removed the deleted backfiller suites and updated status,
approve, and daemon E2E coverage to exercise current-state behavior only.

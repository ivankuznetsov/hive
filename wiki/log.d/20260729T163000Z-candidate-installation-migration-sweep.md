---
date: 2026-07-29
area: update, refactor-patrol, migration
---

# Candidate installation migration sweep before daemon restart

- Added `hive refactor-patrol-migrate-installed`, a candidate-only command that
  backfills registered-project identities, sweeps the invoking user's complete
  installation registry through `RegisteredProjectMigrationCoordinator`, and
  prints the exact typed installation status it persists. Every other
  user-scoped installation runs the same shipped boundary on first eligible
  use.
- Isolated failed/retryable project rows now remain successful sweep evidence;
  only structural command failures fail the candidate process.
- `hive update` invokes that command through the stable post-update Hive binary
  after package replacement and before restart, whether or not a daemon had
  been running. A prior daemon restarts in `ensure` when candidate execution
  fails structurally.
- Shutdown-acknowledgement failures now warn that the daemon may already be
  stopped and give exact `status` and `start` recovery commands without an
  automatic uncertain-quiescence restart.

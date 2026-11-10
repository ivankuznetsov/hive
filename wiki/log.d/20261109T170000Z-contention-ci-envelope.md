## 2026-11-09 — Runtime contention CI: wider exhaustion envelope, orphan-group coverage

- The held-lock exhaustion qualification
  (`test/integration/runtime_database_contention_test.rb`) gave every
  bookkeeping budget 0.2 seconds against a 0.6-second writer hold. Pre-barrier
  phases (launch writes, worker registration, heartbeats) share that budget
  with four concurrent supervisors and the daemon, so on a loaded CI runner one
  supervisor exhausted *before* reaching the selected operation
  (`claim exhausted ... (0 busy tries)`, `heartbeat exhausted`), never wrote its
  barrier byte, and the parent timed out at the supervisor barrier. Reproduced
  locally on two pinned CPUs (`taskset -c 0,1`, 1 of 3 runs). The envelope is now
  `EXHAUST_BUDGET_SEC = 1.0` against `EXHAUST_LOCK_HOLD_SEC = 2.0` (5 of 5 runs
  green on two pinned CPUs). Production budgets are unchanged.
- `ProcessIdentity#terminate_orphan_group` returns `:identity_mismatch` for a
  malformed recorded process group (`Integer()` raising `TypeError`/
  `ArgumentError`) without signalling; a unit test now covers that arm, which
  lost incidental coverage when `Errno::EPERM` got its own `:still_alive` rescue.

# 2026-09-29 — Quiescence treats a busy writer as contention

- `Hive::Daemon::Quiescence#call` labeled a storage exception
  `deadline_exhausted` only after the drain cutoff had passed, and
  `storage_error` otherwise. SQLite can raise BUSY right away (lock upgrades
  are not waited on), so a busy writer was sometimes reported as a storage
  failure. That made
  `test_busy_sqlite_writer_is_bounded_before_closure_and_leaves_admission_open`
  flaky in CI.
- A busy or locked error anywhere in the cause chain
  (`SQLiteSupport.busy_error?`) now reports `deadline_exhausted` (admission
  stays open), whatever the timing. A deterministic test raises a wrapped
  BUSY before the cutoff.

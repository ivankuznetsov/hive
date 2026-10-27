# 2026-10-27 — Resume service-restore deadline tests are clock-injected

- `test/unit/daemon/resume_test.rb` no longer relies on wall-clock timing to
  reach `Hive::Daemon::Resume#restore_services`'s deadline branches. The
  bounded-restore test freezes the injected `monotonic:` clock so the
  `Timeout.timeout` interrupt (the `rescue Timeout::Error` arm) always fires
  after admission reopens; a new test spends the budget inside proof removal
  so the `timeout <= 0` arm is taken without starting the restorer.
- Previously a real 0.1s budget meant slow CI could spend it before the
  restore (leaving `quiescence.rb`'s `Timeout::Error` lines uncovered and
  failing the exact-100% gate on unrelated PRs) or before reopen (failing
  `admission_reopened`). No production change.

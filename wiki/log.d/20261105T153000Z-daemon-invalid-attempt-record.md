# 2026-11-05 — One task's invalid attempt record no longer kills the daemon

**Action:** A `patrol-fix` inbox task created without a task id (`meta.yml`
`id:` null, likely while the global task counter lock was busy) made
automatic dispatch build an attempt with `task_id: nil`.
`Hive::Attempts::Record#validate_subject!` rejected it, the translated
`RepositoryError` escaped `Daemon::Dispatcher#dispatch_prioritized_rows`, and
the global daemon exited; systemd hit its restart limit and every project's
automation stopped.

`Attempts::Repository#translate_store_error` now raises the dedicated
`Hive::Attempts::InvalidAttemptRecord < RepositoryError` when the record
itself fails validation. The daemon row loop rescues only that subclass,
logs `blocked` with `reason: attempt_admission_failed` once per task and
message, and continues with the remaining rows. Every other attempt
repository error, including storage failures, still propagates (pinned by the
existing `test_automatic_dispatch_does_not_hide_other_attempt_repository_errors`).

**Verification:** daemon dispatcher (417 runs) and attempts store tests pass;
the new row-loop regression test fails on the previous code with the exact
production error.

**Open:** why patrol can create a task without an id is recorded in
[[gaps]].

# 2026-09-24 — Commit lock waits for a queue to drain

- `Hive::Lock::COMMIT_LOCK_TIMEOUT_SEC` rose from 30 to 120 seconds, and
  `HIVE_COMMIT_LOCK_TIMEOUT_SEC` overrides it with a positive number of seconds.
  Each hive/state commit stages task files and logs; on a large state branch
  (observed: 13 GB, ~147k tracked files, `git status` alone ~3s) a few stage
  commands started together queued past 30s and failed with exit 75
  (`ConcurrentRunError`) although no holder was stuck.
- The runtime control-plane SQLite busy timeout rose from 5s to 15s, and CLI
  boundaries now wrap an SQLite lock-busy exception as the retryable
  `ConcurrentRunError` (exit 75, "runtime database busy") via
  `Hive::InternalError.wrap`, instead of `internal error` (exit 70). `hive act`
  previously crashed with `SQLite3::BusyException: database is locked` while
  the daemon and several stage commands were writing.

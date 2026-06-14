---
title: Hive::Lock
type: module
source: lib/hive/lock.rb
created: 2026-04-25
updated: 2026-06-14
tags: [lock, concurrency, flock, commit-lock]
---

**TLDR**: Two locking primitives — per-task `.lock` (long-lived, EXCL file create with PID-reuse defence) and per-project `.commit-lock` (short-lived, bounded flock for the brief hive-state git-commit window).

## Per-task lock

`with_task_lock(task_folder, payload = {})` wraps a block:

1. `acquire_task_lock` opens `<task_folder>/.lock` with `WRONLY | CREAT | EXCL` (atomic create-or-fail), writes a YAML payload merged with `base_payload`.
2. On `Errno::EEXIST`, calls `stale_lock?`. If stale, deletes and retries up to 3 times. If live, raises `Hive::ConcurrentRunError`.
3. The block runs with the lock held.
4. `release_task_lock` deletes the lock file in `ensure`.

`base_payload`:
```ruby
{
  "pid" => Process.pid,
  "started_at" => Time.now.utc.iso8601,
  "process_start_time" => process_start_time(Process.pid)
}
```

The runner adds `slug:` and `stage:` to the payload. `Hive::Agent` later injects `claude_pid` via `update_task_lock`, used by `hive status` to detect stale agents.

## Stale-lock detection (`stale_lock?`)

1. Read `.lock`; YAML-parse safely. Unparseable → treat as stale.
2. Validate `pid` is an integer.
3. `Process.kill(0, pid)`:
   - `ESRCH` → process is gone → stale.
   - `EPERM` → process exists but we can't signal → not stale (live).
4. Read `process_start_time` from the lock and the live `/proc/<pid>/stat` field 22. If recorded ≠ live → PID was reused after we locked → stale.

This is the PID-reuse defence: a fresh process with the same PID would have a different start time.

## `process_start_time(pid)`

Reads `/proc/<pid>/stat` when procfs is available, splits on `") "` to handle `(comm)` containing arbitrary characters, and returns field 22 (overall) — index 19 of the tail because the tail starts after `(comm) `. On macOS, BSD, or containers without readable procfs, it falls back to `ps -o lstart= -p <pid>`. Returns `nil` only when both probes fail, in which case stale-lock detection gracefully degrades to the PID-only check.

## Per-project commit lock

`with_commit_lock(project_hive_state_path)`:

1. Ensures the directory exists.
2. Opens `<dir>/.commit-lock` with `RDWR | CREAT, 0o644`.
3. Polls `flock(LOCK_EX | LOCK_NB)` until it acquires the lock or the 30-second `COMMIT_LOCK_TIMEOUT_SEC` deadline expires.
4. On timeout, raises `Hive::ConcurrentRunError` with `lock_path: <dir>/.commit-lock`.
5. Yields while the file descriptor is open; closing the descriptor releases the flock.

The lock file is *not* deleted on release (it persists for cheap re-locking). Held for milliseconds — long enough to wrap one `git add && git commit`.

Current command consumers include `hive run` post-stage commits, `hive new` capture commits, approve/finding toggles, marker clears, drops, and migrate commits. The lock serializes shared `.hive-state` worktree index writes across those processes; it does not make `Hive::GitOps#hive_commit` self-locking.

## Why two-level

Per-task lock is held for the entire `hive run`, including long execute/review passes, and only applies once a task folder exists. If that same lock were used for hive-state git commits, two concurrent runs on different tasks of the same project would serialize for the full agent runtime, while non-run writers such as `hive new` would still need a project-wide gate. The commit lock lets long stages run in parallel and only blocks during the commit instant.

## Tests

- `test/unit/lock_test.rb` — happy path, concurrent acquire raises, stale-lock retry, bounded commit-lock timeout, and commit-lock parallelism.
- `test/integration/new_test.rb` — `hive new` wraps the captured-task hive-state commit in the project commit lock.

## Backlinks

- [[modules/task]] · [[modules/agent]] · [[modules/git_ops]]
- [[commands/run]] · [[commands/new]] · [[commands/approve]] · [[commands/findings]]
- [[state-model]]

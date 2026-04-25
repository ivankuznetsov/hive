---
title: Hive::Lock
type: module
source: lib/hive/lock.rb
created: 2026-04-25
updated: 2026-04-25
tags: [lock, concurrency, flock]
---

**TLDR**: Two locking primitives — per-task `.lock` (long-lived, EXCL file create with PID-reuse defence) and per-project `.commit-lock` (short-lived flock for the brief git-commit window).

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

Linux-specific. Reads `/proc/<pid>/stat`, splits on `") "` to handle `(comm)` containing arbitrary characters, returns field 22 (overall) — index 19 of the tail because the tail starts after `(comm) `. Returns `nil` on macOS or any platform without procfs (gracefully degrades — start-time check is skipped, fallback to PID-only).

## Per-project commit lock

`with_commit_lock(project_hive_state_path)`:

1. Ensures the directory exists.
2. Opens `<dir>/.commit-lock` with `RDWR | CREAT, 0o644`.
3. `flock(LOCK_EX)` to serialise.
4. Yields. Releases via `flock(LOCK_UN)` in `ensure`.

The lock file is *not* deleted on release (it persists for cheap re-locking). Held for milliseconds — long enough to wrap one `git add && git commit`.

## Why two-level

Per-task lock is held for the entire `hive run`, including a 45-minute execute pass. If the same lock were used for git commits, two concurrent runs on different tasks of the same project would serialise. The commit lock lets long stages run in parallel and only blocks during the commit instant.

## Tests

- `test/unit/lock_test.rb` — happy path, concurrent acquire raises, stale-lock retry, commit lock parallelism.

## Backlinks

- [[modules/task]] · [[modules/agent]]
- [[commands/run]]
- [[state-model]]

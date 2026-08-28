## UpdateCheck::State closes the lock fd when flock fails

- `Hive::UpdateCheck::State#acquire_lock` opened `<path>.lock` before calling
  `flock(LOCK_EX)`; when `flock` raised (`SystemCallError`/`IOError`, e.g.
  ENOLCK on exotic filesystems), the rescue logged and returned `nil` without
  closing the already-opened fd, leaking one fd per mutating op for as long as
  the failure persisted.
- The rescue now best-effort closes the handle (swallowing close errors) so
  the documented "degrade to best-effort without the lock" path no longer
  leaks descriptors. `with_lock`/`release_lock` behavior is unchanged.
- Regression: `test_flock_failure_closes_the_already_open_lock_fd` in
  `test/unit/update_check_state_test.rb` stubs `File.open` to return a lock
  handle whose `flock` raises `Errno::ENOLCK` and asserts the handle ends up
  closed plus the lock-error event is logged.

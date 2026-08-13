## Remove unused whole-event module dispatcher

- Removed `Modules::Dispatcher#dispatch_event` after the retired `EventRouter`
  left no production caller; tracked, reflective-dispatch, documentation, and
  available-history searches found only its direct unit test.
- Retained the hook-scoped `dispatch` path used by the durable module runtime,
  including replay, dry-run, admission, retry, and persistence coverage.
- `Dispatcher` is shipped library code, so untracked external callers remain
  the compatibility boundary.

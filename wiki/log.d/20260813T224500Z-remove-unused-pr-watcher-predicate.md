## Remove unused PR watcher predicate

- Removed `Daemon::PrMergeWatcher#watching?`, a convenience predicate called
  only by three unit assertions.
- Retained the surrounding durable open/closed state, retry/backoff, and
  unreadable-store fail-closed assertions through the live watcher surfaces.

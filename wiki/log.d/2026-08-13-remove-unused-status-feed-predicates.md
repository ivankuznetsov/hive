# Remove unused status-feed predicates

- Removed `Web::StatusFeed::State#fresh?` and `#degraded?`, which had no
  production callers.
- Retargeted transition and subscriber tests to the canonical `availability`
  value consumed by `StatusBroadcaster`; unavailable-state behavior is
  unchanged.

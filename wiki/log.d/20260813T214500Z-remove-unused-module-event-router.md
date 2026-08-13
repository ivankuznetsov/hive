## Remove unused module event router

- Removed the unconstructed `Modules::EventRouter` facade, its stale daemon
  require, and the facade-only test. Tracked producers publish directly to the
  durable `EventLedger` through `EventPublisher` and `DaemonRuntime`.
- Retained the event publisher, ledger, daemon scheduling, dispatch, and
  idempotency coverage for every supported durable module event.

## Unified durable recovery lifecycle

- **Authority**: `RecoveryCoordinator` now owns every recoverable-marker
  transition. Telegram, TUI, Rails, CLI/action, recorder, and daemon healing
  submit a current observation and derived freshness token through the neutral
  `Hive::Recovery::API` instead of clearing state independently.
- **Durability**: Dispatch-request v4 persists canonical task and marker
  identity across `admitted`, `cleared`, `dispatched`, and `terminal` phases.
  Bounded, request-keyed lock shards serialize claims, phase updates, and
  pruning; request IDs are filesystem-safe, and restart replay re-resolves
  identity and reruns safety before mutation. A daemon crash after queue claim
  but before attempt admission requeues the recovery transition instead of
  deleting the only durable path out of a markerless state. Reobserving an
  unchanged blocked transition is read-only, avoiding a per-tick queue rewrite.
  Legacy marker occurrences also bind state-file mtime, task IDs are backfilled
  before healer admission, post-clear launch failures defer for one hour, and
  malformed claims are quarantined with byte-preserving evidence.
- **Surfaces**: Operational status exposes one canonical
  queued/cooldown/running/blocked/terminal/unavailable receipt. Rails overlays
  it without a second fleet scan and disables or hides Retry according to that
  lifecycle. The real demo recorder now exercises the same queued path from a
  sandbox instead of deleting `plan.md`. Recovery-aware agent contracts are
  published only as operational-status v2 and act v2. A one-off migration
  updated every in-repository producer, consumer, fixture, and operating skill;
  the obsolete v1 recovery contracts were removed rather than retained as
  compatibility code.
- **Verification**: Focused coordinator, queue, dispatcher, operational,
  adapter-authority, bot, TUI, Rails, status-feed, schema, and recorder syntax
  coverage pins the shared behavior.

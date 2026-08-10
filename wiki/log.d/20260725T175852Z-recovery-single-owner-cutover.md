## Recovery single-owner cutover

- `Hive::Daemon::RecoveryCoordinator` is the sole production owner of
  recoverable-marker clearing and retry admission. Every user-facing adapter
  submits through `Hive::Recovery::API`; `StaleAgentHealer` is the only
  automatic scheduler.
- `hive migrate` supplies the one-off random identity for old `ERROR`,
  `REVIEW_ERROR`, `REVIEW_STALE`, and `REVIEW_CI_STALE` occurrences. Runtime
  recovery rejects id-less markers, and the public recovery-aware status/action
  contracts now support v2 only.
- Removed the TUI kill-code loop, Telegram clear route, healer retry counters
  and exhaustion state, stage-specific clear/requeue machinery, and the
  attempt-loss compatibility marker. Retry count now comes from durable
  recovery-request history.
- Focused attempt-loss and authority verification currently covers 43 runs and
  175 assertions; the full recovery and repository checkpoints follow before
  merge.
- Hardened the cutover against concurrent migration and scheduler churn:
  marker-id backfill is now compare-and-swap, post-clear dispatch failure
  preserves the durable request and reapplies the shared cooldown, queue and
  recovery projection share one scan per tick, and terminal receipt pruning is
  paced hourly.
- Closed recovery projection and input-boundary gaps: requestors are a strict
  enum including `operator`, id-less rows surface the migration blocker,
  queued state requires a canonical request id, active custom terminal
  agent/council stages remain retryable, and max-pass review escalations can
  resume only through the TUI's explicit post-edit `r` gesture.

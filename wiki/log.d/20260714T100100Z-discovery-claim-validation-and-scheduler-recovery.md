# 2026-07-14 — Discovery claim validation and scheduler recovery coverage

- Closed the "zombie fence" gap in `JobRecordValidator`: attempts of kind
  `discovery_claim` now get the same schema discipline as action claims — at
  most one active attempt, strictly increasing generations, complete claim
  shapes, plus append-only history with monotonic heartbeats and legal state
  transitions — so a record with two active discovery attempts can no longer
  be written and later resurrect a stale prior-generation token through
  `active_discovery_attempt`.
- Added behavioral coverage for daemon crash recovery: an expired discovery
  claim is reclaimed by `RefactorPatrolScheduler#reserve` only when the
  injected `claim_resolver` proves the recorded owner gone (`:resolved`);
  `:unresolved` keeps the claim and fails the reservation closed.
- Corrected misleading comments: heartbeat renewal refuses only on proof of
  death/PID reuse (fail-closed lives in the takeover paths), patrol due-check
  throttles commit at evaluation time (not on reserve), and the pending-marker
  `cancel` calls in `Dispatcher#dispatch_patrol_with_gates` serve only the
  legacy no-arbiter `tick` path.

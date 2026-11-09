# 2026-11-06 — status: a queued retry behind a terminal attempt is not running

**Action:** Fixed `hive status --operational --json` reporting
openclaw-shopping:merge-and-root-commits-are-never-queued-for-wiki-42e4ddbf1fcc
as `state: running` (`retry_in_flight`, `recovery.status: running`,
`phase: dispatched`) indefinitely while `liveness.status` was `not_running`,
attempt `0595da53-…` was `terminal/failed`, and dispatch request
`69d2202b134b674e6c5558fcda10b142` was back in `state = 'queued'` in a project
the daemon would not dispatch. `summary.states.running` stayed 1, so drain
consumers waited forever.

**Root cause:** `RecoveryCoordinator#receipt_for_request` maps the durable
recovery phase `dispatched` to receipt status `running` without looking at the
dispatch request's state or the referenced attempt. The dispatcher publishes
that receipt into the operational snapshot, the overlay turns it into the
`retry_in_flight` disposition, and operational status classifies that as
`running`/agent.

**Change:**
- New `RecoveryCoordinator#projected_receipt_for_request(request,
  dispatch_enabled:)` used by `Dispatcher#durable_recovery_receipts`. `running`
  stays only when the request is `claimed`/`admitted`/`awaiting_delivery` or the
  attempt is `launching`/`running` (attempt-store errors keep `running`).
  Otherwise a `queued` request becomes receipt `queued` with reason
  `retry_awaiting_dispatch` (scheduler) or `project_dispatch_disabled`
  (operator, with remediation) when `project_enabled?` is false and the request
  is not an explicit action recovery; `completed`/`cancelled` becomes
  `unavailable`/`recovery_transition_pending`. Retry/escalation fields are kept.
- `OperationalSnapshot` overlay maps the disabled case to the new decision
  `retry_dispatch_disabled`; operational status classifies it as
  `needs_repair`/operator. The enabled case stays `retry_pending` →
  `waiting_on_provider_or_scheduler`/scheduler.
- Control-flow uses of `receipt_for_request` are unchanged.

**Docs:** `wiki/commands/status.md`, `wiki/modules/daemon.md`.

**Tests:** recovery coordinator (queued + terminal attempt → queued; claimed/
admitted/awaiting_delivery + live attempt → running; disabled project →
operator-owned `project_dispatch_disabled`; unreadable store stays running),
dispatcher (dispatch enablement passed per project and for action recoveries),
operational snapshot overlay, operational status (not running, summary count 0,
explicit disabled reason, escalation retained).

---
title: Attached recovery requests close when their attempt ends
type: change
created: 2026-11-15
updated: 2026-11-15
tags: [daemon, recovery, dispatch-requests, attempts, operational-status]
---

Dogfood b6d6001077 (2026-11-14): after a daemon restart, the first-sight
`advance` dispatch of a todero Patrol Fix generation won admission. The
queued markerless recovery request for the same generation was then admitted
as `existing_live`. `mark_dispatched` recorded the other request's attempt,
but `AdmissionTransition` binds `claim_attempt_id` only on the row of the
request that created the attempt. The recovery row stayed `queued` with no
delivery, `reconcile_attempt_deliveries` never completed it, `resume` kept
reporting it `running`, and the healer kept returning it instead of
rearming. Nothing dispatched the task from 19:59 UTC until the task changed
the next day. The 2026-11-06 openclaw-shopping status fix had the same root:
it relabelled such a request as a queued retry, but nothing ever dispatched it.

- `RecoveryCoordinator#close_finished_dispatch` closes a `queued` request in
  phase `dispatched` once its attempt is final, using that attempt's outcome
  (`lost` for a lost attempt), with `close_reason`
  `dispatched_attempt_finished`. A missing or unrecorded attempt closes as
  `lost` with `dispatched_attempt_unknown`. Live attempts and unreadable
  attempt storage leave it alone. Marker recoveries then get the guarded
  `repair_failed_terminal_marker`.
- `DispatchRepository#complete_recovery!` makes the close one transition,
  only from `queued`: terminal recovery plus a `completed` row, which frees
  the active-subject slot for a later rearm.
- `Dispatcher#reconcile_dispatched_recoveries` runs after delivery
  reconciliation every tick and once at start, for owned, in-scope projects.
  It logs `dispatch_request_recovered` with the reason, attempt, and outcome,
  and isolates per-request and queue-read failures. It never dispatches.
- Terminal receipts carry the close reason as `reason`.

Tests: `test/integration/manual_workflow_retry_test.rb` (real admission
reproduces the restart race, the stuck state, the close, marker repair, and
idempotency), `test/unit/daemon/recovery_coordinator_test.rb` (finished,
unknown, unrecorded, lost, live, unreadable, owned-delivery, rearm,
`complete_recovery!` guard), and `test/unit/daemon/dispatcher_test.rb`
(start reconcile, project scoping, idempotency, failure isolation).

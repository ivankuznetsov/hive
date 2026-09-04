---
title: Hive::Attempts
type: module
source: lib/hive/attempts/, lib/hive/runtime_control_plane/admission_transition.rb
created: 2026-07-16
updated: 2026-09-04
tags: [attempts, admission, sqlite, recovery, capacity]
---

**TLDR**: Hive admits task-stage work as independent durable attempts. One
`attempts` row owns the attempt record plus fixed accounting, failure,
lost-recovery, and terminal-publication facts. Live rows provide capacity.
Retries use deterministic dispatch-request identity, not an attempt graph.

## Boundary

`Hive::Attempts::API` is the public admission facade. The CLI, bot, web, daemon,
and module-hook paths use the same dispatcher. A successful admission starts a
detached supervisor; callers may attach or observe but do not own the worker's
lifetime.
The API does not own or reap child processes after handoff.

SQLite owns machine-local coordination only. Task Markdown and task journals
remain workflow authority. Large logs and outputs live in the content-addressed
payload store and may have multiple `payload_references` rows.

## One attempt row

The attempt row contains:

- immutable task, request, generation, provider, route, and worker identity;
- mutable lifecycle state and lease version;
- admission charge/refund facts;
- one counted failure fact for runaway-cohort accounting;
- lost-recovery phase, revision, deterministic recovery request, and completion;
- terminal receipt digest and monotonic publication acknowledgements.

These are fixed one-to-one facts. Hive does not maintain separate accounting,
capacity-reservation, lost-outcome, failure-event, publication-obligation, or
attempt-relationship tables. `payload_references` remains separate because it
is genuinely one-to-many. `attempt_failure_cohorts` remains separate because it
aggregates failures across attempts without representing provider usability.

## Admission and capacity

Admission runs in one immediate SQLite transaction. It checks active
`launching` and `running` attempts, applies the configured global/project/daily
limits, selects a current provider route when configured, and inserts the new
attempt. Terminal and lost attempts release capacity by definition; no
reservation row is required.

Duplicate work for the same task/generation attaches to the existing live
attempt. Records and lifecycle mutations are fenced by state, lease version,
record digest, task generation, and ownership generation.

## Lost recovery

A lost attempt never
projects a recovery marker; its row remains the recovery authority.
Recovery stays direct without adding an event bus.

A proven-lost attempt advances through a monotonic recovery phase. Recovery
creates or finds one deterministic dispatch request. When that request admits a
replacement, the new attempt is an ordinary independent attempt and the source
attempt becomes irreversibly recovery-complete in the same transaction.
Concurrent healers therefore converge on one request and one admission without
predecessor or successor fields. Request retention cannot reopen recovery
authority because completion remains on the source attempt.

Dirty worktree captures are sealed into the content-addressed payload store
before the recovery becomes ready. Admission links those sealed bytes to the
replacement in the same transaction, so source retention cannot delete output
that the replacement inherited.

## Terminal publication

Terminal receipts remain durable until their fixed consumers acknowledge them.
Acknowledgement fields live on the attempt row and are monotonic; replay is
safe after a daemon restart. Result delivery itself lives on the associated
dispatch-request row and is at-least-once across an external send boundary.
After all acknowledgements, the row remains active until log archival and
failure-cohort reconciliation finish and the daemon durably marks promotion.

## Maintenance

Only the daemon schedules periodic attempt maintenance. Its timer is
process-local. Each run performs row-bounded and monotonic-time-bounded,
keyset-ordered, idempotent queries for pending finalizations and expired
payload/log candidates and continues past an individual row failure. A restart
may repeat safe work; it does not restore a claim or cursor from SQLite.

## Tests

- `test/unit/attempts/`
- `test/unit/runtime_control_plane/admission_transition_test.rb`
- `test/unit/daemon/attempt_loss_healer_test.rb`
- `test/integration/provider_routing_admission_test.rb`
- `test/integration/provider_routing_recovery_test.rb`

See [[state-model]], [[modules/provider_routing]], [[modules/daemon]], and
[[token-usage]].

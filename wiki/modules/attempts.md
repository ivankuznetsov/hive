---
title: Hive::Attempts
type: module
source: lib/hive/attempts/, lib/hive/runtime_control_plane/admission_transition.rb
created: 2026-07-16
updated: 2026-09-04
tags: [attempts, admission, sqlite, recovery, capacity]
---

**TLDR**: Hive admits task-stage work as independent durable attempts. One
`attempts` row owns the attempt record plus fixed accounting,
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
- lost-recovery phase, revision, deterministic recovery request, and completion;
- terminal receipt digest and monotonic publication acknowledgements.

These are fixed one-to-one facts. Hive does not maintain separate accounting,
capacity-reservation, lost-outcome, failure-event, publication-obligation, or
attempt-relationship tables. `payload_references` remains separate because it
is genuinely one-to-many. Patrol retry pacing reads the latest final attempt
for the same task, generation, stage and runtime. A failed, cancelled or lost
attempt delays automatic retry by `AgentLimit.retry_cooldown_sec`; success or
changed inputs/runtime clears that delay. Explicit retry bypasses pacing, not
live capacity or unresolved-loss recovery. There are no cohort counters or probes.

`request_id` is immutable provenance, not a foreign key to the disposable
dispatch queue. Completing or pruning a request must not change an attempt
snapshot or prevent same-tick finalization. The unique request index still
prevents duplicate admission. Finalization retains its full-record equality
checks; mismatches are not ignored or retried inside the tick.

For the preceding SQLite layout only, explicit `Database#migrate!` recognizes
the exact old schema fingerprint and atomically rebuilds the attempts table
without that foreign key. It preserves rows, indexes and CHECK constraints,
validates the new schema and foreign keys before committing, and rolls back
on failure. Other tables, token history and payload references are retained.
Normal open/startup rejects the old schema and does not upgrade it. Stop all
writers and take an external SQLite backup before invoking the migration.
Previously nulled request IDs cannot be reconstructed by this schema change.

SQL columns own lifecycle and identity values. `details_json` contains only
execution details absent from those columns; `subject_json` holds the structured
subject and `terminal_receipt_json` holds the receipt once. `Record.from_row`
reconstructs the validated in-memory value. No full `record_json`, record digest,
or SQL-versus-record synchronization protocol remains. Receipt digests still
bind publication evidence; they are not a second live-state authority.

## Admission and capacity

Admission runs in one immediate SQLite transaction. It checks active
`launching` and `running` attempts, applies the configured global/project/daily
limits, selects a current provider route when configured, and inserts the new
attempt. Terminal and lost attempts release capacity by definition; no
reservation row is required.

Duplicate work for the same task/generation attaches to the existing live
attempt. Records and lifecycle mutations are fenced by state, lease version,
task generation, and ownership generation. Only changed execution columns are
written; accounting and publication acknowledgements remain independent.

## Lost recovery

A lost attempt never
projects a recovery marker; its row remains the recovery authority.
Recovery stays direct without adding an event bus.

A proven-lost attempt advances through a monotonic recovery phase. Recovery
creates or finds one deterministic dispatch request. When that request admits a
replacement, the new attempt is an ordinary independent attempt and the source
attempt becomes irreversibly recovery-complete in the same transaction.
The replacement derives a fresh ownership generation from the exact post-clear
task bytes while retaining the task's numeric input epoch; admission must match
that generation to the recovery request before launching the worker.
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
After all acknowledgements, the row remains active until log archival finishes
and the daemon durably marks promotion.

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

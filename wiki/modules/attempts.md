---
title: Hive::Attempts
type: module
source: lib/hive/attempts/, lib/hive/runtime_control_plane/admission_transition.rb
created: 2026-07-16
updated: 2026-10-02
tags: [attempts, admission, sqlite, recovery, capacity]
---

Failed automatic stage transitions now use the shared recovery backoff ladder,
including when the source stage remains `COMPLETE`. The latest same-generation
terminal receipt supplies the failure time and retry charge; each admitted
successor increments that charge. No extra timer table or watcher is involved.
Explicit operator retries retain their existing bypass of automatic pacing.
The project daily dispatch cap remains the emergency brake.

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
It also exposes the dispatcher's read-only provider-route decision for daemon
readiness. That projection uses the tick's existing admission view and never
persists an attempt or starts a worker.

Supervisor self-reentry preserves canonical directories from the running Ruby
interpreter's resolved load path. This includes dependencies loaded without
RubyGems activation, as in the isolated CLI scenario harness. It does not re-read
ambient `RUBYLIB`; `bin/hive` places its own source directories first.

The private supervisor route is selected before public CLI dispatch. Its detached
wrapper removes inherited Bundler and Ruby toolchain variables before it re-enters
Hive, anchoring startup to the invoked Hive checkout rather than a caller bundle
or transient test home. The capability and handshake descriptors are the only
inherited launch authority.

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
for the same task, generation, stage and runtime. A failed, cancelled, interrupted or lost
attempt delays automatic retry by `AgentLimit.retry_cooldown_sec`; success or
changed inputs/runtime clears that delay. Explicit retry bypasses pacing, not
live capacity or unresolved-loss recovery. There are no cohort counters or probes.

An interrupted attempt is terminal non-success, not a successful checkpoint
and not an inferred loss. Its version-2 terminal receipt binds the pause
generation and retains the last durable checkpoint, output references, and log
reference. The supervisor publishes interruption only after its worker and
recorded process group have stopped; a natural completion that wins first keeps
its genuine success receipt. A restarted controller may finalize the same
outcome only after identity checks prove both the wrapper and worker group are
absent, and the attempt lease compare-and-swap prevents a later interruption
from replacing an already committed terminal result.

During quiescing, an already admitted supervisor stops ordinary heartbeat
writes and may use its single bounded cleanup-write window to publish the
terminal receipt. A quiesce signal uses the lifecycle generation and clamps
worker termination to the persisted escalation slice without consuming the
generation's finalization reserve. The same signal outside quiescing remains
an ordinary cancellation. The installation controller aggregates any receipt
the supervisor already committed for that generation with interruptions it
finishes after verified wrapper and worker-group absence.

Process-tree polling, a PID/start fingerprint, inherited invocation tokens, and
an ambient or transient systemd scope are not complete descendant custody. The
Linux delegated-cgroup adapter is eligible only for an explicitly established
installation-exclusive domain when delegation is writable and parent escape is
blocked. Automatic detection does not adopt the ambient service cgroup; the
default therefore remains `unverified` until a launch adapter can inject that
exclusive domain. Membership snapshots freeze the domain and recurse through
descendant cgroups; unreadable member identities remain unresolved instead of
disappearing from the inventory. Wrapper exit retains its process registration
until both root identity and descendant-domain absence are proven, including
after controller restart. Darwin and hosts without that custody remain fail
closed whenever unregistered descendants may exist.

`interrupted` remains fully implemented and independently tested at the real
supervisor/reconciler boundary. Command-level interruption is intentionally not
claimed by increment 1, because its pre-drain gate refuses an agent root before
drain or signals. That end-to-end path belongs to the later custody increment;
the idle success contract does not manufacture an interruption receipt merely
to exercise it.

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

## Attempt frame log and tail recovery

`lib/hive/attempts/stream_log.rb` owns append-time recovery for the binary
JSON-lines attempt log. Construction never mutates existing log bytes for
recovery: it securely opens an append descriptor and a retained read
descriptor, verifies that both reference the same regular inode, and captures
the replayable sequence and physical size as one lock-held snapshot. Strict
reads through the retained descriptor are the sequence authority, so an I/O
error during construction or reconciliation fails closed instead of becoming
an empty sequence-zero log. Public `StreamLog.read` remains tolerant of
filesystem errors and malformed records. Constructor failure releases any
acquired log lock and closes both log descriptors and an owned custody
descriptor without replacing the initiating error.

Every append takes the per-instance mutex and then the log's exclusive advisory
lock. While holding both, it inspects the physical last byte, optionally seals
the tail, reconciles the sequence when its coherent sequence/size snapshot is
stale, writes and flushes the complete frame, and only then publishes the new
sequence and size snapshot. An unchanged healthy snapshot avoids a full replay
scan, but does not skip physical tail inspection. The same mutex serializes
`close`; a forked child must independently open its own `StreamLog`. This
contract coordinates `StreamLog` writers only—direct writers that ignore the
advisory lock remain outside its scope.

An unterminated tail is isolated by completely appending the fixed invalidating
separator `"#\n".b` and defensively flushing it before sequence selection or
frame writing. Recovery preserves every existing byte: it never truncates,
rewrites, parses, or generally repairs the damaged fragment. The `#` keeps even
a syntactically valid JSON value without its newline unreadable after the
separator establishes the next boundary; a newline-terminated malformed record
is already bounded and remains untouched.

A separator write or flush error, including `Errno::EINTR`, escapes unchanged
without an internal retry or sequence advance. A caller-controlled retry on the
same or a reopened instance re-inspects the physical tail, so no separator, a
partial separator, and a complete separator before a write or flush raises all
converge safely. `syswrite` bypasses Ruby buffering, so the separator flush is a
defensive assertion rather than an additional durability barrier. A successful
append establishes independently replayable bytes and their line boundary in
the kernel page cache for process-crash recovery; it does not promise survival
of power loss or kernel panic. `close` retains the existing `fsync` behavior.

A separator `SystemCallError` during Supervisor output drain remains fatal: the
outer handler stops the worker group and returns `ExitCodes::SOFTWARE`; the
failed chunk has no successful frame, and the drain path neither silently
discards it nor retries inside `StreamLog`. For a one-shot fault, the diagnostic
append can re-inspect and recover the tail, and the attempt terminalizes as
failed with a readable log reference. If the fault persists into the
diagnostic append, no success or terminal receipt is manufactured; the running
row remains for lost recovery, and cleanup releases the log and custody
handles.

## Maintenance

Only the daemon schedules periodic attempt maintenance. Its timer is
process-local. Each run performs row-bounded and monotonic-time-bounded,
keyset-ordered, idempotent queries for pending finalizations and expired
payload/log candidates and continues past an individual row failure. A restart
may repeat safe work; it does not restore a claim or cursor from SQLite.

## Tests

- `test/unit/attempts/`
- `test/unit/attempts/stream_log_test.rb`
- `test/integration/attempts_stream_log_recovery_test.rb`
- `test/unit/attempts/client_test.rb`
- `test/unit/attempts/log_archive_test.rb`
- `test/unit/attempts/supervisor_test.rb`
- `test/unit/runtime_control_plane/admission_transition_test.rb`
- `test/unit/daemon/attempt_loss_healer_test.rb`
- `test/integration/provider_routing_admission_test.rb`
- `test/integration/provider_routing_recovery_test.rb`

See [[state-model]], [[modules/provider_routing]], [[modules/daemon]], and
[[token-usage]].

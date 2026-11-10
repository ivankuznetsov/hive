---
title: Hive::Attempts
type: module
source: lib/hive/attempts/, lib/hive/runtime_control_plane/admission_transition.rb
created: 2026-07-16
updated: 2026-11-09
tags: [attempts, admission, sqlite, recovery, capacity]
---

Failed automatic stage transitions now use the shared recovery backoff ladder,
including when the source stage remains `COMPLETE`. The latest same-generation
terminal receipt supplies the failure time and retry charge; each admitted
successor increments that charge. No extra timer table or watcher is involved.
Explicit operator retries retain their existing bypass of automatic pacing.
The project daily dispatch cap remains the emergency brake.

Claimed launch reservations retain matching owners past the first-heartbeat
deadline, and the exact live wrapper can commit a delayed first heartbeat under
the original lease CAS. Unverifiable claimed owners are retained only until
`first_heartbeat_deadline + 2 * (first_heartbeat_deadline - claimed_at)`, derived
from persisted claim diagnostics. Restart and timer changes cannot move this
ceiling. Reconciliation rechecks the row, wrapper and worker custody: a proven
live worker still reserves capacity; otherwise valid pending completion wins
before the distinct `first_heartbeat_owner_unverifiable_ceiling` loss. Running
unverifiable owners retain their existing conservative policy. Once the wrapper
is gone or mismatched, mismatched worker identities permit pending completion
replay or loss and do not keep lost recovery pending. Matching live workers,
unverifiable groups and permission-denied termination still fence successors;
termination reports unresolved custody as `still_alive` instead of a mismatch.

Worker registration continues through cancellation, timeout and short worker
exit, without releasing a cancelled worker's execution gate. During quiescence
the first identity-only checkpoint has one bounded `worker:<attempt_id>` cleanup
slot, separate from terminal/interruption cleanup; it cannot change outputs or
the work checkpoint. Pending receipt references resolve against the canonical
store root while continuing to reject redirected descendants and linked files.

Typed bookkeeping reasons survive client errors, Execute and Review markers,
lost-recovery projections, healer logs and recovery terminal-marker repair.
`runtime_bookkeeping_busy` and the claimed-owner ceiling remain attributable to
runtime bookkeeping instead of becoming generic agent/provider failures.

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
That resolved `RUBYLIB` (Hive's lib, agent-cli-runtime, and every activated
gem) is private to Hive and is inherited by the supervisor and worker. Commands
the worker runs for the project (review CI in `CiFix.run_ci_once`, council
`CommandRunner`, agent CLI launches) therefore merge
`Hive::ProjectCommandEnvironment.overrides`, which unsets `RUBYLIB`, `RUBYOPT`,
`RUBYGEMS_GEMDEPS`, `GEM_HOME`, `GEM_PATH`, Bundler keys, and `BUNDLER_ORIG_*`.
Child `hive` calls do not need the inherited path: `bin/hive` (and the HIVE_BIN
wrapper that execs it) put Hive's lib and agent-cli-runtime on `$LOAD_PATH`
themselves and resolve gems through RubyGems.

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

## Attempt memory cap

On Linux hosts with a systemd user manager, `DetachedLauncher` starts each
durable attempt wrapper in a transient `hive-attempt-<digest>.scope`
(`systemd-run --user --scope --collect -p Delegate=yes`). The scope contains the
supervisor, the agent CLI, and every tool shell, ad-hoc probe, test run, and
review CI command the attempt starts, so a cap on the scope bounds the whole
attempt. `ConfiguredDispatcher` reads `daemon.attempt_memory_max` (default
`"6G"`) and `daemon.attempt_memory_swap_max` (default `"0"`) from the freshly
loaded global daemon block via `LaunchPolicy.memory_limits` and the launcher
adds `--property=MemoryMax=…`, `--property=MemorySwapMax=…`, and, on systemd
>= 253 (probed once per launch with `systemd-run --version`),
`--property=OOMPolicy=continue`.

- `OOMPolicy=continue` is load-bearing: with systemd's default `stop`, one
  kernel OOM kill inside the scope tears down the whole scope, including the
  supervisor, which turns a bounded failure into a lost attempt. With
  `continue`, the kernel kills only the largest process (typically the runaway
  probe), and the agent keeps running and sees its tool command die.
- Default reasoning: on the 16 GB dogfood host, runaway Codex reviewer probes
  reached 4-4.6 GB within seconds and nearly OOMed the host. 6G stays above
  normal agent and test peaks while stopping a runaway well before the host
  limit. Swap 0 makes the cap take effect immediately instead of after a swap
  storm. Large projects whose test suites need more memory raise
  `daemon.attempt_memory_max`; `false` disables the cap (and the swap cap,
  which applies only together with the memory cap).
- No-op on macOS, on hosts without a user bus or `systemd-run`, and for plain
  spawn paths. Those keep the previous uncapped behavior.
- OOM classification: the supervisor reads its own cgroup v2
  `memory.events` `oom_kill` counter before it spawns the worker and after
  the worker exits. If the counter increased and the worker died by `SIGKILL`
  without a Hive-forced termination, it appends
  `hive-attempt: failure_reason=memory_limit_exceeded oom_kills=N` to the
  attempt log and sets the synthesized patrol-fix diagnostic's `agent_reason`
  to `memory_limit_exceeded`. If only a descendant was killed, it logs a
  `memory_limit_oom_kills=N` notice and keeps the worker's own outcome. The
  terminal receipt schema is unchanged (see `wiki/gaps.md`).

## Attempt scope leftovers

A finished worker does not end its scope by itself. systemd keeps a
`hive-attempt-*.scope` `active (running)` while any process is left in its
cgroup, and the supervisor only signals the worker's process group. A tool
that calls setsid(2) escapes that group but not the cgroup: `podman run`
leaves `conmon` and `pasta` behind. On 2026-11-09 a todero review agent's test
container kept its terminal attempt's scope active for about 7.5 hours, which
blocked hivedev spike windows that require zero attempt units.

`Attempts::ScopeReaper` closes this gap. The supervisor calls it once the
worker is gone, on every exit path: success, failure, provider hold/limit
(a failed outcome), timeout, cancellation, quiesce interruption, an
unexpected supervisor error, a lost lease, and an early refusal. On the
normal path it runs after `run_worker` and before the attempt log is closed
and the terminal receipt is committed.

- It acts only when the supervisor's own cgroup (`/proc/self/cgroup`) is
  exactly `hive-attempt-<sha256(attempt_id)[0,24]>.scope`, the unit
  `DetachedLauncher` names via `ScopeReaper.unit_name`. Anywhere else (macOS,
  no user manager, plain spawn, test processes, a different attempt's scope,
  a sub-cgroup) it is a no-op (`unscoped`).
- It lists every pid in the scope and its descendant cgroups (`cgroup.procs`,
  bounded to 4096), never the supervisor itself. It sends SIGTERM, waits up to
  the supervisor's kill grace (`--kill-grace-sec`, shortened during
  quiescence), then sends SIGKILL and waits up to 2 s more. Each round
  re-reads membership, so processes forked meanwhile are caught. Every pid is
  re-checked against the scope's cgroup right before it is signalled, so a pid
  reused outside the scope is never signalled.
- When the last process exits, systemd collects the scope (`--collect`). The
  supervisor cannot use `systemctl --user stop` on its own scope because that
  would kill the supervisor before it commits the receipt.
- When anything was left, the attempt log gets one supervisor-channel line:
  `hive-attempt: scope_leftovers {"unit":…,"status":"reaped"|"incomplete"|"unavailable","reaped":[{"pid":…,"comm":…}],"survivors":[…]}`.
  Only pid and `comm` are recorded, not command lines, which can carry
  secrets. A clean scope logs nothing. The terminal receipt schema is
  unchanged.
- Reaping never raises into the supervisor. Containers whose processes live
  in a separate cgroup (podman with the systemd cgroup manager puts them in
  their own `libpod-*.scope`) are outside this attempt's scope and are not
  touched. Only the leftovers inside the attempt scope are killed.

Hive's own drain and wait paths do not count scopes. Operational task
liveness uses task-lock and agent pid identity. Daemon status liveness and
quiescence use `owned_processes` rows and attempt record states, and
`ProcessRegistry#reconcile_exited_processes!` uses wrapper session and
process-group absence. None of them treats a terminal attempt's scope as
running, so they gained no orphan output. The scope-level check that
blocked was in hivedev (`Window.live_attempt_scopes` and the spike
scripts' "no `hive-attempt-*` unit" precondition). The unit description
(`Hive durable attempt <attempt_id>`) in `systemctl --user list-units
'hive-attempt-*'` already names the attempt behind a leftover scope.

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

The immutable attempt value contract is v5. Task-stage subjects may carry a
controller-admitted typed proposal binding stored in the existing
`subject_json` column. Under the current-format-only runtime database model
there is no separate version-fence migration for this member; the base schema
stays at v2 and an older binary rejects such a row as an invalid attempt record
when it decodes the closed subject. Worker context validation binds
`hive proposal submit|evaluate TASK` source workers to the task's current
stage, like `approve`; every other `proposal` subcommand fails closed.

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
descriptor without replacing the initiating error, including asynchronous
unwinds such as `Interrupt`.

Every append takes the per-instance mutex and then polls for the log's exclusive
advisory lock with nonblocking `flock` and a five-second monotonic deadline.
While holding both, it inspects the physical last byte, optionally seals the
tail, reconciles the sequence when its coherent sequence/size snapshot is
stale, writes and flushes the complete frame, and only then publishes the new
sequence and size snapshot. Reconciliation streams complete records, validates
their replayability—including canonical Base64 padding bits, and skipping
non-object JSON lines and out-of-range sequences exactly as public replay
does—and tracks only the
maximum sequence; it does not decode payloads, allocate frames, sort, or retain
the whole log. An unchanged healthy
snapshot avoids that scan, but does not skip physical tail inspection. Any
append failure invalidates the snapshot, so the next append performs streaming
strict reconciliation under the lock. The same mutex makes `close` and
`closed?` wait behind an in-flight append; a forked child must independently
open its own `StreamLog`. This contract coordinates `StreamLog` writers
only—direct writers that ignore the advisory lock remain outside its scope.

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

`close` flushes and syncs before closing any descriptor. A flush or sync error
leaves the writer and custody handles open for a caller-controlled retry; this
lets Supervisor append one terminal diagnostic and retry close after a one-shot
sync failure. Once synchronization succeeds, all descriptor and custody cleanup
steps run while preserving the first cleanup error. If lock-release recovery
cannot install a replacement append descriptor, the instance remains explicitly
closeable until its retained reader and custody handles have also been released;
an opened but rejected replacement is closed immediately.

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
- `test/unit/runtime_control_plane/admission_transition_test.rb`
- `test/unit/daemon/attempt_loss_healer_test.rb`
- `test/integration/provider_routing_admission_test.rb`
- `test/integration/provider_routing_recovery_test.rb`

See [[state-model]], [[modules/provider_routing]], [[modules/daemon]], and
[[token-usage]].

Runtime writer transactions report monotonic acquisition wait separately from
lock hold, including commit/rollback, with stable operation labels. Debug
measurements are enabled by `HIVE_SQL_DEBUG=1`; holds over one second warn even
without debug logging. Measurements never log SQL or projection payloads and
are emitted after SQL and writer-fence release. See
`docs/implementation/runtime-database-contention.md` for observed evidence.

Attempt bookkeeping uses `BookkeepingRetry` with a single monotonic deadline
per operation. Admission through wrapper registration, claim, first heartbeat
and worker registration shares `attempt_bookkeeping_timeout_sec` (30 seconds
by default), capped at 30 seconds and clamped strictly inside persisted
launch/first-heartbeat expiry.
The detached handoff exports the remaining absolute deadline through its private
supervisor transport; it never retries the launcher, process spawn or agent body.
A delayed claim still requires the capability, unchanged lease and a matching
live identity for the current wrapper.

Later heartbeat and terminal writes retain separate 600-second deferral
envelopes. Scheduled heartbeat and worker-registration retries leave output
capture, cancellation and stage timeout polling active between tries. Every
SQL try is capped at one second or its remaining budget, with connection/fence
work sharing that cap and reserving a positive SQL wait. Backoff starts at
50 ms with bounded jitter and caps at one second. There is no independent
try-count termination rule. Writer measurements also separate connection,
fence and SQLite acquisition time, including failures.

Only actual SQLite BUSY errors (including extended primary result codes),
wrapped driver causes and the runtime file-fence busy type are retryable.
Messages containing `database is locked` alone are ordinary errors. Exhaustion
raises `BookkeepingBusy`, a TEMPFAIL carrying the attempt, operation, count,
elapsed time and `runtime_bookkeeping_busy` reason; it does not enter generic
launch-handoff failure handling. The repository resolves an identical ambiguous
terminal commit from its authoritative receipt rather than overwriting it.

Guarded attached recovery uses `Recovery::API` with an explicit manual execution
policy. The coordinator alone validates a persisted recovery observation and
repairs markers. Its query-only evidence is scoped by project and task before
applying a bound; tokens include the request revision, phase and post-clear
binding. A fresh operator action can expedite an admitted or cleared request
without charging another retry. Other recovery callers retain queued admission.

The bounded restart investigation is recorded in
[[log.d/20261108-004-operator-attempt-restart-investigation]]. On the exercised
Linux host, real external supervisors survived disposable services modeling
all three shipped kill policies, for direct execute and attached review work.
Actual application-service restarts and the historical incident remain
unverified; no production orphan policy was changed based on that probe.

`Attempts::API#fetch` and `#attach` expose canonical observation and read-only
attachment without constructing internal repositories or clients in recovery
adapters. A contended request admission re-reads the canonical request attempt
and verifies its task/stage/generation binding before returning existing-live
or terminal replay. Genuine loss remains a ledger state; manual recovery maps
it to the `lost` outcome and retains its canonical end time.

Manual retry validates every accepted, existing-live, or terminal-replay
admission result against the recovery request's task, project, slug, stage,
generation and post-clear progress before binding or attaching. The daemon's
marker-recovery consumer applies the same fence. A foreign semantic owner
leaves the request cleared and unbound, so a fresh operator retry remains
available after that owner ends.

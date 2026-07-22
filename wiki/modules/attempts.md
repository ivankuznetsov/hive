---
title: Durable task attempts
type: module
source: lib/hive/attempts/
created: 2026-07-16
updated: 2026-07-22
tags: [attempts, ownership, leases, daemon, recovery]
---

**TLDR**: Every accepted task-stage launch has one immutable attempt ID and
one versioned JSON lease/receipt under `$HIVE_HOME/attempts/v1/`. A detached
supervisor wrapper—not the CLI, bot, web process, or daemon—owns the worker
group, heartbeat, framed output, exit status, and terminal receipt. The daemon
reconciles and applies policy; it does not own or reap task agents.

## Module map

| Module | Responsibility |
|--------|----------------|
| `Record`, `Store` | Write v2 records, ingest v1/v2, perform locked guarded transitions with atomic write/fsync/rename persistence, and copy nested record/checkpoint/receipt values through `Hive::StringifyKeys`. |
| `Capability`, `Context` | Generate one-time launch authority, authenticate the exact worker process/task/stage, revalidate generation at the mutation boundary, and expose process-local compatibility projections after transport variables are scrubbed. |
| `Generation` | Bind stable task identity, intended stage, and a workflow progress token into the semantic ownership key. |
| `Dispatcher` | Resolve receipt replay, live duplicate attachment, loss deferral, capacity, fresh admission, and explicit successors. |
| `DetachedLauncher` | Reject unsupported platforms before handoff, create a POSIX session, and start the private supervisor route. |
| `Supervisor` | Claim, first-heartbeat, spawn the existing Hive command, heartbeat, frame output, enforce timeout/cancellation, and terminalize. |
| `Client` | Tail frames read-only and replay a terminal result. It performs one final drain after observing a terminal or lost record so frames published during the decisive record fetch are not dropped. Interrupt means detach; it never signals the owner group. |
| `CommandDispatch` | Give `hive run` and workflow stage commands one attach-result policy: shared durable dispatch, lost-attempt translation, receipt exit propagation, and single-document JSON fallback when a failed worker emitted no stdout. |
| `Reconciler`, `ProcessIdentity` | Adopt without `wait2`, detect PID/start/session/group mismatch, preserve suspects, expire launches, and normalize loss. |
| `DirtyStateCapture`, `LostOutcomeStore` | Inventory partial git/untracked/binary work without mutation and make cleanup/successor policy restart-idempotent. |
| `LegacyBackfiller` | Create a compatibility lease only when legacy task/PID/start identity is trustworthy. |

## Storage and identity

```text
$HIVE_HOME/attempts/v1/
├── records/<attempt-id>.json
├── logs/<attempt-id>.frames
├── outputs/<attempt-id>/...
└── generation-locks/{admission.lock,<sha256>.lock}
```

The record carries attempt/request/predecessor IDs, task and generation
identity, the exact admitted worker argv, a SHA-256 digest of a random launch
capability, provider, retry charge, revisions, wrapper/worker fingerprints,
deadlines, checkpoint, integrity references, diagnostics, and loss or receipt
fields. The capability itself is never persisted. Large payloads remain
owner-private referenced files with canonical relative path, byte size, and
SHA-256.

Record construction/readers and store transitions all use the same
non-mutating `Hive::StringifyKeys` transform as the task journal and projection.
It recursively copies hashes/arrays and stringifies keys while leaving scalar
values unchanged, preserving the former `Record.deep_copy` contract without a
second normalization implementation.

Task generation—not request ID—is semantic idempotency. Its progress token
hashes both the stage artifact and this task's deterministic dependency-
admission verdict. Duplicate live deliveries receive the same attempt and an
unchanged completed generation replays its receipt, while a dependency wait
that later becomes clear advances generation instead of replaying the stale
exit-75 receipt. A loss successor has a new attempt ID but inherits generation,
predecessor, outputs, worktree/branch, and an incremented retry charge. An
omitted or empty successor-output override inherits the predecessor's complete
output set; only a non-empty explicit override replaces it.

Condition projection adds an explicit numeric `task_input_epoch` to attempt
records/context while retaining the prerequisite's opaque ownership generation
as `ownership_generation`. That wire shape is `hive-attempt` v2; the original
v1 schema remains unchanged. Old v1 records remain readable and bridge to
epoch 0 in memory; they are not rewritten. Every non-legacy condition event must
name a durable attempt whose task/stage ownership matches the record. Retry and
adoption reuse the numeric epoch when accepted inputs are unchanged.

## State protocol

```text
launching/unclaimed --capability + claim CAS--> launching/claimed
launching/claimed --first heartbeat CAS--> running
running --receipt CAS--> terminal(succeeded|failed|cancelled)
launching|running --expiry/reconciliation CAS--> lost
```

`terminal` and `lost` cannot become live again. Each mutation compares attempt
ID, generation, observed state, lease version, and active deadline while
holding the generation lock. Configurable defaults are heartbeat 5s, stale
30s, launch timeout 30s, and first-heartbeat timeout 30s. The daemon resolves
those timers from the admitted task's project on every initial or successor
dispatch. The wrapper must win first heartbeat before it may spawn the stage
worker.

## Admission and execution

Public `hive run` and workflow verbs enter `Attempts::Entrypoint`. Bot/web v3
requests, daemon queue/auto-advance, and recovery use the same dispatcher;
pending v2 requests remain readable. The launcher double-forks into a distinct
session. The dispatcher gives the wrapper a one-time random capability through
an inherited pipe; the private `__attempt-supervise` route accepts no worker
command argv and can claim only by proving that capability against the
immutable record digest. The supervisor then executes the record's exact argv.
Admission is reported accepted after the launcher confirms the claim or
reports the authenticated wrapper in its durable `launching` state. A
false/malformed handoff or launcher exception marks the unclaimed reservation
`lost` and returns a retryable deferral; if the wrapper won the claim race, the
dispatcher re-reads and adopts it instead of creating an overlapping owner.
Capacity scan and reservation creation take the shared admission lock before
the generation lock. That fixed order makes the limit decision atomic across
different tasks and projects, rather than only among duplicates of one
generation.

For Hive workers, startup is held behind a second inherited-FD gate. The
supervisor first persists the worker PID, start fingerprint, session, and
process group, then releases the gate. `Context` installs only when the record
is running and its capability, exact process identity, argv, resolved task,
and intended stage all match. `hive run` and generic `hive approve` bind that
stage to the task's current descriptor position; stage-specific workflow verbs
bind it to their registered target. Immediately before the first task mutation,
the worker recomputes its generation while the task lock is held and rejects a
stale admission; this closes the dispatch-to-execution window for task or
dependency changes. It immediately deletes every inherited
`HIVE_ATTEMPT_*` key, so agent processes and nested Hive commands cannot inherit
the admission bypass. The attempt transport cannot supply a dedicated store
override, and production exposes neither public context construction nor a
`Context.with` override. The authenticated context remains only in the worker
process. An attached client records whether any stdout frame was replayed.
`Hive::Attempts::CommandDispatch` applies that result identically for `hive
run` and workflow verbs: a non-zero terminal result with no worker stdout is
routed through the owning command's normal versioned JSON error envelope
instead of returning an empty document; a worker-emitted document is never
duplicated; lost attempts without output become the command's typed concurrent
run error; and every other non-zero receipt preserves its exit status.

This is an application ownership boundary, not privilege separation. Hive's
configured global attempt store, its `HIVE_HOME`/`XDG_STATE_HOME`/`HOME`
process configuration, and the same-UID Ruby process are trusted; code with
arbitrary environment, write, or monkeypatch access can bypass application APIs.
Treating provider agents as hostile at that OS boundary requires a separate
broker identity and protected signing/storage authority (tracked in
[[gaps]]).

Legacy task locks and markers gain optional `attempt_id`, opaque
`task_generation`/`ownership_generation`, and numeric `task_input_epoch`
projections inside the worker. They remain readable
compatibility/evidence records, not ownership truth. The internal log is
append-only sequenced JSON frames with timestamp, channel, and base64 bytes;
the CLI still presents ordinary stdout/stderr and the receipt exit status.

## Reconciliation and capacity

At daemon startup and before each healer/admission tick, fresh heartbeat plus
matching PID/start fingerprint is adopted. Stale-but-matching or unverifiable
identity is suspect and still reserves capacity. Missing/reused identity can
win the one-way loss CAS. Adoption never calls `wait2` because wrappers are not
children of a restarted daemon.

Launching, running/suspect, and confirmed-live or unsafe-cleanup lost leases
are authoritative capacity. A lost lease stops reserving only after cleanup
records the worker as absent, terminated, or never identified. Status rows
are a deduplicated legacy fallback only when no durable identity exists.
Evidence order is terminal receipt, matching current-generation marker, then
git inventory; commits or a clean worktree never prove stage success.

## Definitive loss

A live worker group is signalled only when start fingerprint and session/group
membership still match. Drift becomes a durable manual outcome. Once absent,
`DirtyStateCapture` records HEAD, porcelain-v2 status, binary patches, and
hashed untracked metadata without stash/reset/checkout/clean/add/commit.

One `ERROR reason=attempt_lost` compatibility marker is projected. Only the
lease loss healer consumes it; legacy and recoverable-error discovery skip it.
Retry budget is durable `retry_charge` (maximum three), so restart or a new ID
cannot reset it. A successor replays the immutable admitted workflow argv and
flags; if the command already moved the task, only its locator is retargeted
and a satisfied `--from` assertion is removed. Queue claims follow an admitted
successor and later complete from its receipt. If the daemon crashes after
admission but before stamping the queue claim, restart repairs correlation by
the immutable request ID before deciding whether the claim is live.

## Tests

Focused tests are under `test/unit/attempts/` and
`test/unit/daemon/attempt_loss_healer_test.rb`. The YAML subprocess replay
`durable_attempt_1849_replay.yml` creates three commits, kills the temporary
CLI group, verifies the execute lease remains running without a daemon, and
accepts completion only from one wrapper receipt.

## Backlinks

- [[architecture]] · [[state-model]] · [[commands/run]] · [[modules/daemon]] · [[testing]]

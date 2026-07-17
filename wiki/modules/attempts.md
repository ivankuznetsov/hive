---
title: Durable task attempts
type: module
source: lib/hive/attempts/
created: 2026-07-16
updated: 2026-07-17
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
| `Record`, `Store` | Validate v1 records and perform locked guarded transitions with atomic write/fsync/rename persistence. |
| `Capability`, `Context` | Generate one-time launch authority, authenticate the exact worker process/task/stage, and expose process-local compatibility projections without inherited environment trust. |
| `Generation` | Bind stable task identity, intended stage, and a workflow progress token into the semantic ownership key. |
| `Dispatcher` | Resolve receipt replay, live duplicate attachment, loss deferral, capacity, fresh admission, and explicit successors. |
| `DetachedLauncher` | Reject unsupported platforms before handoff, create a POSIX session, and start the private supervisor route. |
| `Supervisor` | Claim, first-heartbeat, spawn the existing Hive command, heartbeat, frame output, enforce timeout/cancellation, and terminalize. |
| `Client` | Tail frames read-only and replay a terminal result. Interrupt means detach; it never signals the owner group. |
| `Reconciler`, `ProcessIdentity` | Adopt without `wait2`, detect PID/start/session/group mismatch, preserve suspects, expire launches, and normalize loss. |
| `DirtyStateCapture`, `LostOutcomeStore` | Inventory partial git/untracked/binary work without mutation and make cleanup/successor policy restart-idempotent. |
| `LegacyBackfiller` | Create a compatibility lease only when legacy task/PID/start identity is trustworthy. |

## Storage and identity

```text
$HIVE_HOME/attempts/v1/
├── records/<attempt-id>.json
├── logs/<attempt-id>.frames
├── outputs/<attempt-id>/...
└── generation-locks/<sha256>.lock
```

The record carries attempt/request/predecessor IDs, task and generation
identity, the exact admitted worker argv, a SHA-256 digest of a random launch
capability, provider, retry charge, revisions, wrapper/worker fingerprints,
deadlines, checkpoint, integrity references, diagnostics, and loss or receipt
fields. The capability itself is never persisted. Large payloads remain
owner-private referenced files with canonical relative path, byte size, and
SHA-256.

Task generation—not request ID—is semantic idempotency. Duplicate live
deliveries receive the same attempt; completed duplicates replay the receipt.
A loss successor has a new attempt ID but inherits generation, predecessor,
outputs, worktree/branch, and an incremented retry charge.

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
Admission is reported accepted only after the launcher confirms that claim. A
false/malformed handoff or launcher exception marks the unclaimed reservation
`lost` and returns a retryable deferral; if the wrapper won the claim race, the
dispatcher re-reads and adopts it instead of creating an overlapping owner.

For Hive workers, startup is held behind a second inherited-FD gate. The
supervisor first persists the worker PID, start fingerprint, session, and
process group, then releases the gate. `Context` installs only when the record
is running and its capability, exact process identity, argv, resolved task,
and intended stage all match. It immediately deletes every inherited
`HIVE_ATTEMPT_*` key, so agent processes and nested Hive commands cannot inherit
the admission bypass. Worker input cannot select an alternate attempt-store
path, and production exposes neither public context construction nor a
`Context.with` override. The authenticated context remains only in the worker
process. An attached client that observes `lost` raises a retryable Hive error,
letting `hive run --json` and workflow `--json` commands emit their normal
versioned error envelopes instead of exiting with an empty stdout document.

This is an application ownership boundary, not privilege separation. Hive's
configured global attempt store and same-UID Ruby process are trusted; code
with arbitrary write/monkeypatch access to both can bypass application APIs.
Treating provider agents as hostile at that OS boundary requires a separate
broker identity and protected signing/storage authority (tracked in
[[gaps]]).

Legacy task locks and markers gain optional `attempt_id` and
`task_generation` projections inside the worker. They remain readable
compatibility/evidence records, not ownership truth. The internal log is
append-only sequenced JSON frames with timestamp, channel, and base64 bytes;
the CLI still presents ordinary stdout/stderr and the receipt exit status.

## Reconciliation and capacity

At daemon startup and before each healer/admission tick, fresh heartbeat plus
matching PID/start fingerprint is adopted. Stale-but-matching or unverifiable
identity is suspect and still reserves capacity. Missing/reused identity can
win the one-way loss CAS. Adoption never calls `wait2` because wrappers are not
children of a restarted daemon.

Launching and running/suspect leases are authoritative capacity. Status rows
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

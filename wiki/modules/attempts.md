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
identity, provider, retry charge, revisions, wrapper/worker fingerprints,
deadlines, checkpoint, integrity references, diagnostics, and loss or receipt
fields. Large payloads remain owner-private referenced files with canonical
relative path, byte size, and SHA-256.

Task generation—not request ID—is semantic idempotency. Duplicate live
deliveries receive the same attempt; completed duplicates replay the receipt.
A loss successor has a new attempt ID but inherits generation, predecessor,
outputs, worktree/branch, and an incremented retry charge.

Condition projection adds an explicit numeric `task_input_epoch` to attempt
records/context while retaining the prerequisite's opaque ownership generation
as `ownership_generation`. Old v1 records remain readable and bridge to epoch
0 in memory; they are not rewritten. Every non-legacy condition event must
name a durable attempt whose task/stage ownership matches the record. Retry and
adoption reuse the numeric epoch when accepted inputs are unchanged.

## State protocol

```text
launching/unclaimed --claim CAS--> launching/claimed
launching/claimed --first heartbeat CAS--> running
running --receipt CAS--> terminal(succeeded|failed|cancelled)
launching|running --expiry/reconciliation CAS--> lost
```

`terminal` and `lost` cannot become live again. Each mutation compares attempt
ID, generation, observed state, lease version, and active deadline while
holding the generation lock. Configurable defaults are heartbeat 5s, stale
30s, launch timeout 30s, and first-heartbeat timeout 30s. The wrapper must win
first heartbeat before it may spawn the stage worker.

## Admission and execution

Public `hive run` and workflow verbs enter `Attempts::Entrypoint`. Bot/web v3
requests, daemon queue/auto-advance, and recovery use the same dispatcher;
pending v2 requests remain readable. The launcher double-forks into a distinct
session. Its wrapper invokes the old command body with
`HIVE_ATTEMPT_INTERNAL=1`, so provider code stays lease-unaware and cannot
redispatch recursively.

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
cannot reset it. Queue claims follow an admitted successor and later complete
from its receipt.

## Tests

Focused tests are under `test/unit/attempts/` and
`test/unit/daemon/attempt_loss_healer_test.rb`. The YAML subprocess replay
`durable_attempt_1849_replay.yml` creates three commits, kills the temporary
CLI group, verifies the execute lease remains running without a daemon, and
accepts completion only from one wrapper receipt.

## Backlinks

- [[architecture]] · [[state-model]] · [[commands/run]] · [[modules/daemon]] · [[testing]]

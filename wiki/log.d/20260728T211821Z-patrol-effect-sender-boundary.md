---
title: Patrol effect sender boundary
date: 2026-07-28
tags: [patrol, architecture-patrol, recovery, concurrency]
---

**Action:** Closed Architecture Refactor U2 review findings F01, F02, F04,
and F05 at the effect boundary. Replaced persisted sender leases, claim tokens,
generations, and expiry takeover with a process-local keyed mutex plus a
stable, never-unlinked `0600` flock file. Persisted effect cells now contain
only `prepared`, `dispatch_uncertain`, or terminal recovery facts. Exact
absence permits redispatch only for product-owned local retry-safe sink maps;
remote branch, pull-request, and issue absence remains unresolved.

`OccurrenceEffects` now constructs each authoritative terminal receipt inside
the occurrence mutation and returns the exact persisted bytes on replay.
Finalization rejects every nonterminal or unbound effect, finalized
occurrences reject new dispatch, and ordinary scheduler retries allocate a
durable positive attempt generation in the occurrence identity.

**Proof:** Characterization covers forked and threaded sender contention,
crash uncertainty, unsafe remote absence, retry-safe local reset, repeated
denial/reconciliation at different clocks, nonterminal finalization,
finalized-dispatch refusal, and concurrent schedule-attempt allocation.

**Architecture authority:** JobStore accepts schema v3 only and owns the
immutable occurrence and intake-transition pointers plus append-only
claim/action/job/diagnostic transition identities. Released v2 jobs have no
runtime reader or converter. The explicit confirmed fresh-start boundary
archives only their exact opaque directory and admits an empty v3 namespace.

Publication supersession, terminal-proof materialization, plan/link/block,
claim-scoped receipt updates, and discovery mutations now pass through explicit
transition coordinators. Claim process attachment and heartbeat renewal pass
through one narrow operational port. Durable diagnostic episode generations
prevent a later identical block from replaying an earlier terminal receipt,
and restart recovery inventories only active occurrences before reconciling
exact transition ids.

Fresh architecture intake treats only a missing pre-enrollment job as the
absence of a reusable occurrence. Corrupt jobs and every other intake failure
still fail closed; the first intake then reserves its occurrence and writes the
v3 aggregate through the authoritative transition gateway.

All intake, discovery, plan, and action coordinators now build and reconcile
the same transition-evidence byte shape through one shared utility. Mutation
payloads remain bound to the gateway idempotency key without being redundantly
threaded through the persisted transition record.

**Operations and boundaries:** Ownership cutover/rollback quiescence now
includes ordinary active occurrences, architecture active occurrences, and
incomplete jobs. Ordinary and architecture recovery failures emit bounded
structured identity/error/retry diagnostics with backoff. The component
catalog forbids direct construction of shared stores, gateways, and transition
collaborators outside named roots, while a static contract confines semantic
JobStore mutators to transition ports.

The ordinary occurrence store now uses the shared managed-directory contract
for its reads, stable locks, and atomic writes. Its scheduler recovery
inventory streams one record at a time, retaining only bounded occurrence IDs
and the oldest reservation, and canonical byte-identical replays avoid an
unnecessary write and directory fsync. No new persisted snapshot or recovery
state was introduced.

**Additional proof:** The complete command integration surface enrolls fixtures
through the real v3 intake contract and covers both first intake and existing
occurrence reuse. Focused ActionRunner, scheduler, dispatcher, migration,
storage, and component-boundary suites remain green.

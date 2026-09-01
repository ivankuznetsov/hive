---
title: Hive::ProviderHealth
type: module
source: lib/hive/provider_health.rb, lib/hive/provider_health/*.rb, lib/hive/runtime_control_plane/admission_transition.rb
created: 2026-08-10
updated: 2026-08-29
tags: [provider-accounts, models, circuits, sqlite, probes, audit]
---

**TLDR**: `Hive::ProviderHealth` owns conservative eligibility state for
explicitly routed provider accounts and exact models. Its sole authority is the
shared SQLite runtime control plane. It never schedules retries, charges a
budget, creates a successor, dispatches work, or owns task state.

## Storage and scope

`Hive::ProviderHealth::Repository` stores typed circuit and audit rows in
`provider_circuits` and `provider_audit`. Each provider account and exact
provider/model pair is an independent scope. Route eligibility composes both
scopes at read time:

- an account block or open circuit excludes every model on that account;
- a model block or open circuit excludes only that model;
- a manual block is independent of automatic open/closed state;
- `eligible_at` produces a half-open read view without a write;
- every accepted mutation advances the scoped generation.

The previous file journals, projections, probe-intent files, replay repair,
compaction, and quarantine protocols were removed in the one-way SQLite
cutover. SQLite integrity failures belong to runtime-control-plane recovery;
there is no second provider-health repair store.

## Admission and probe ownership

Route selection first reads a bounded health snapshot. Final admission is
owned by `RuntimeControlPlane::AdmissionTransition`, which revalidates circuit
generations and eligibility in the same immediate transaction that freezes the
routing policy, checks task identity and capacity, claims any half-open probes,
and inserts the attempt. A stale observation rolls back the entire admission.

Probe ownership is represented by typed columns on the circuit row and an
immutable binding in the attempt routing record. No callback or provider work
runs inside the admission transaction.

## Terminal evidence

`AttemptObserver` consumes immutable terminal or lost explicit-attempt records.
It reconstructs the admitted route, generation vector, ownership fence, and
probe bindings from the record. Probe success closes a matching half-open
circuit; failure, cancellation, or proven loss reopens it conservatively.

Shared-health evidence must have an allowlisted failure class and provenance,
an admitted route, an attempt ID, and an integrity-bearing output reference.
The repository checks the terminal attempt identity directly in SQLite before
accepting evidence. The idempotency key binds the terminal receipt identity and
safe evidence fingerprint, so replay is a no-op. Stale generations and fenced
attempts are recorded as rejected audit rows without changing the circuit.

When evidence has no reset hint, the cooldown comes from the immutable routing
policy snapshot for that attempt ownership generation; a missing policy uses
the conservative repository default. Policy reads occur before the circuit
mutation transaction.

## Operator controls

`hive circuits` is the only public provider-health administration surface.
`block`, `unblock`, and `reset` require an exact configured scope, a fresh
generation, a validated reason, trusted local actor identity, and explicit
`--yes` approval. Mutation and its bounded audit receipt commit together.

`unblock` removes the manual block. `reset` clears automatic health and stale
probe ownership while preserving a manual block. None of these actions touches
attempt outcomes, task markers, recovery receipts, retries, successors, or
dispatch. See [[commands/circuits]].

---
title: Patrol Fix radical simplification
type: change
created: 2026-08-21
tags: [patrol, patrol-fix, refactor, migration, publication]
---

Patrol Fix now has one live path from discovery to delivery. Ordinary and
Architecture Patrol reserve accepted immutable snapshots directly in one
project `AdmissionStore` through thin source adapters; the handoff outbox and
its duplicate lifecycle are gone. Historical ordinary findings use only the
one-time `script/migrate_patrol_findings.rb` importer, whose strict metadata
scan is scoped to matching Patrol Fix idempotency keys. There is no runtime
cutover, epoch, dual-write, rollback, or migration controller.

The complete Patrol module-migration subsystem is gone: first-party Patrol
module packages and adapters, migration CLI/coordinator/ownership locks,
shadow comparison, occurrence/effect/outbox recovery, evidence and
qualification reports, installed/live qualification packaging, schemas, and
their tests were deleted. Native Patrol schedulers now reserve and complete
directly against StateStore or JobStore. Architecture intake derives immutable
job identities directly from the manifest; they do not point at a sidecar
journal.

The legacy ordinary and Architecture remediation engines are removed.
`Hive::GithubPublication` is the sole branch/PR mutation engine for both coding
Open PR and Patrol Fix Publish, with exact-head reconciliation and safe retries
for provably absent effects.

Patrol Fix uses standard task/status/TUI/bot/Watch contracts. The bespoke
project operational projection, daemon composition edge, schema, consumer
validation, and UI summaries are deleted; the frozen host schemas match their
existing versions. The daemonless web Patrol page reads the existing bounded
ordinary and Architecture queries directly and remains read-only.

Inbox, Fix, and Review share one managed-agent custody launch helper; Runner
has no mutable test registry. Scheduled and post-merge Architecture mapping
share one exact detached-SHA rig. Successfully admitted scheduled results and
fully finalized post-merge groups compact safely, replacing lifetime fail-stop
caps without deleting pending work. The shared admission inventory likewise
compacts only acknowledged records before reservation and rejects overflow
without wedging active rows; live semantic leases no longer consume the pending
window. Scheduled discovery replays every persisted unconsumed result before
mapping a fresh revision, and disposable exact-revision worktrees clean Git and
filesystem remnants independently.

Parked Patrol Fix outcomes use the standard non-runnable `needs_input` status.
The unreachable custom operational reopen action, token fields, executor, and
eligibility projection fields are removed; only controller-owned Review rework
advances a task generation.

---
title: hive refactor-patrol
type: command
source: lib/hive/commands/refactor_patrol.rb, lib/hive/refactor_patrol/*
created: 2026-07-02
updated: 2026-09-25
tags: [command, refactor-patrol, architecture, json, daemon]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-refactor-patrol) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive refactor-patrol` discovers evidence-backed architecture theses
and routes each one to `fix`, `discuss`, or `dismiss`. Accepted `fix` and
`discuss` dispositions are published to the shared Patrol Fix admission
store. Architecture Patrol does not implement fixes, file issues, create
branches, publish pull requests, or hand work directly to review.

## Archive cutover and one-shot admission

`--archive` is a narrow administrative transition for historical action-era
jobs after their accepted dispositions have been imported into Patrol Fix. It
requires an `authority_revoked` cutover fence and refuses active claims,
linked pending actions, unresolved review errors, or pending remote-effect
continuation evidence. Already-terminal actions remain immutable evidence. It
preserves dispositions, claims, and existing receipts, adds an archive receipt
with the prior outcome to each pending action, and marks the job complete.
Repeating it for a complete job is a no-op.

`--once` runs the daemon's merged-PR intake, classification, durable job
discovery, and downstream handoff path for one project. It does not run the
daemon's separately wired current-main scheduled-slice producer. Intake
deadlines use the configured daemon `pr_merge_poll_interval_sec`; the reported
deadline and persisted checkpoint are the same absolute timestamp.
Classification retries and active claims stay visible before a job exists. A
persisted daemon controller project-drop hold suppresses child discovery and
reports operator action; a blocked scheduler observation still fails the pass
instead of being reported as an operator wait.

## Read-only job-query pagination

`--list` and `--show` read the authoritative durable job ledger through its
immutable query index and never mutate it.

- List pages and per-job show histories default to 100 records; `--limit`
  accepts integers from 1 through 100.
- A list cursor freezes the intake-sequence high-water mark and index
  generation of the issuing snapshot. Jobs recorded later do not change an
  in-flight page, and a cursor from a rebuilt generation fails closed as a
  usage error.
- `--show` truncates history to the same 100-record default and requires
  explicit `--full` for an unbounded history.

Both modes emit `hive-refactor-patrol-jobs.v2`.

## Discovery

On-demand discovery maps the current repository into bounded source and
documentation slices. The reviewer runs read-only and must return complete,
source-backed theses. Hive verifies evidence, confidence, contract risk,
dependency risk, and cross-feature scope before assigning the route. Missing
or unsafe proof becomes `dismiss` or `discuss`; only an admissible thesis uses
the `fix` route.

Merged-PR intake binds discovery to an immutable manifest and an exact clean
analysis worktree. The daemon and manual `--pr` path use the same v4 JobStore
aggregate, generation-fenced discovery claim, feature checkpoints, and
completion envelope. Completed discovery always terminalizes the job; there is
no action phase.

The source adapter reserves accepted dispositions directly in the project
`AdmissionStore` after discovery. The shared
Patrol Fix workflow independently decides which candidate to materialize and
then owns implementation, validation, review, and publication.

## Daemon lifecycle

`Hive::Daemon::RefactorPatrolMergeReconciler` turns eligible merged PRs into
immutable discovery manifests. `Hive::Daemon::RefactorPatrolScheduler` handles
classification, discovery, checkpointing, retries, and post-merge bookkeeping.
Those manifests carry path/status/rename metadata rather than GitHub patch
bodies; the pinned merge worktree is the source of code truth, and patch size
does not gate reconciliation.
Scheduled current-main scans are wired into the daemon through
`ScheduledArchitectureScheduler` and the shared Patrol arbiter. They become due
independently of merged-PR jobs, using `patrol.poll_interval_sec` and the
Architecture engine's daily discovery allowance. They use the existing patrol
scan concurrency budget. The internal `refactor-patrol-scheduled` child claims
one mapped slice at a frozen revision, runs the review, and durably admits the
result before advancing its cursor. Failed or incomplete reviews release the
slice for retry. Successful dispositions use the same source adapter as
post-merge discovery.

Daemon composition and dispatcher regression tests require a periodic launch
when no merged-PR jobs exist. Command integration tests exercise the real slice
producer, default mapper, real reviewer, and durable finding admission with only
the external provider faked; provider failures must leave that cursor retryable.
Both Patrol engines inherit batch feature persistence (`write_features`) from
`Patrol::BaseStateStore`, so non-dry mapping writes to each engine's own namespace.
Dry-run mapping skips persistence and cannot prove this interface works.

The runtime has no action candidate selection, action reservation, fixer,
issue filer, branch creator, PR opener, or review handoff. Historical action
fields remain readable in old v4 job records and bounded query output, but new
jobs always emit `actions: []` and no component can execute those records.

Historical accepted `fix` and `discuss` dispositions can be reserved once with
`script/migrate_patrol_findings.rb [PROJECT_ROOT] [--dry-run]`. The importer
uses the current source adapter, ignores dismissals and historical action
records, preflights occurrence conflicts, and is idempotent against existing
Patrol Fix admissions. It creates no workflow task folders; semantic admission
and normal workflow capacity decide when a reserved disposition materializes.
It does not revive an Architecture Patrol action lane.

## Backlinks

- [[modules/patrol]] · [[modules/daemon]] · [[commands/patrol]]

Scheduled completion waits a full configured poll interval before the next attempt,
including failures and empty slices. Empty or allowance-exhausted children emit
`architecture_patrol_skipped` with a reason, rather than claiming a review closed.

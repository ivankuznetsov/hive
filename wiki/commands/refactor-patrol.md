---
title: hive refactor-patrol
type: command
source: lib/hive/commands/refactor_patrol.rb, lib/hive/refactor_patrol/*
created: 2026-07-02
updated: 2026-08-21
tags: [command, refactor-patrol, architecture, json, daemon]
---

**TLDR**: `hive refactor-patrol` discovers evidence-backed architecture theses
and routes each one to `fix`, `discuss`, or `dismiss`. Accepted `fix` and
`discuss` dispositions are published to the shared Patrol Fix admission
store. Architecture Patrol does not implement fixes, file issues, create
branches, publish pull requests, or hand work directly to review.

## Usage

```bash
# On-demand discovery
hive refactor-patrol my-project
hive refactor-patrol my-project --feature route-home --changed-since origin/main
hive refactor-patrol my-project --entrypoint bin/server
hive refactor-patrol my-project --path lib/payments --json

# Explicit merged-PR replay
hive refactor-patrol my-project --pr 123 --json
hive refactor-patrol my-project --pr https://github.com/acme/app/pull/123 --json

# Daemon/internal immutable-manifest discovery
hive refactor-patrol my-project --job-manifest PATH --json

# Read-only durable history
hive refactor-patrol my-project --list
hive refactor-patrol my-project --list --limit 50 --cursor CURSOR
hive refactor-patrol my-project --show JOB_ID
hive refactor-patrol my-project --show JOB_ID --full --json
```

`--changed-since` is only a filter paired with `--feature`, `--entrypoint`, or
`--path`. PR and job-manifest modes require JSON and cannot be combined with
scope hints. `--list` and `--show` are read-only and cannot be combined with
discovery options.

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
Scheduled current-main scans use the Architecture Patrol launch lane and
reserve their completed dispositions through the same source adapter.

The runtime has no action candidate selection, action reservation, fixer,
issue filer, branch creator, PR opener, or review handoff. Historical action
fields remain readable in old v4 job records and bounded query output, but new
jobs always emit `actions: []` and no component can execute those records.

## Output

Discovery emits `hive-refactor-patrol.v4`, including the immutable source,
analysis SHA, routed dispositions, per-feature completion records, and review
errors. New records contain no publication attempts or actions. `--list` and
`--show` emit `hive-refactor-patrol-jobs.v2`.

## Backlinks

- [[modules/patrol]] · [[modules/daemon]] · [[commands/patrol]]

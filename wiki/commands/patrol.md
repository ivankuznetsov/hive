---
title: hive patrol
type: command
source: lib/hive/commands/patrol.rb, lib/hive/patrol/*
created: 2026-05-28
updated: 2026-09-25
tags: [command, patrol, review, findings]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-patrol) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive patrol` is a discovery command. It reviews a clean snapshot of
the registered project's default branch, records accepted findings under
`.hive-state/patrol/`, and publishes them to the shared Patrol Fix admission
store. It does not edit code, create worktrees, push branches, open pull
requests, or create review tasks.

## Discovery lifecycle

The project must be registered, use the `coding` default workflow, and have
Patrol enabled. `--once` runs one scheduler admission round under the shared
project-execution guard, preserving durable launch allowance, post-reservation
scan cadence, failure backoff, and any persisted daemon controller project-drop
hold.

1. Resolve and strictly fetch the configured default branch, then materialize
   its exact commit as a detached clean scan worktree.
2. Map non-overlapping source, manifest, test, and command-contract features.
3. Select the deterministic SHA-bound feature batch within the ordinary Patrol
   daily launch allowance.
4. Ask the configured reviewer for evidence-backed production findings and
   validate the complete response, source paths, line anchors, snippets, and
   configured validation key.
5. Semantically deduplicate findings against the durable registry. Same-target
   terminal findings remain suppressed; a finding on a newer target starts a
   new recurrence lineage.
6. Persist each newly active finding and reserve its immutable candidate
   snapshot directly in the project Patrol Fix `AdmissionStore`.
7. Update the feature cursor and `last_scanned_sha` only when the corresponding
   review scope completed cleanly, then rebuild the bounded query projection.

The downstream `patrol-fix` workflow owns admission, implementation,
validation, review, and publication. Discovery has no publication policy or
GitHub mutation capability.

## Scheduling and migration

`Hive::Daemon::PatrolScheduler` decides when ordinary discovery is due and
dispatches this command. The project `AdmissionStore` is drained independently
by `Hive::Daemon::PatrolFixAdmissionScheduler`; discovery allowance and workflow
capacity are separate concerns.

Historical local findings can be imported once with
`script/migrate_patrol_findings.rb`. The importer reserves active ordinary
findings and accepted historical Architecture Patrol `fix` and `discuss`
dispositions in the same admission store. It creates no task folders; the
admission scheduler materializes work only after semantic selection and
capacity admission. Legacy ordinary findings without `target_sha` bind to the
current default-branch revision, and secret-like evidence is redacted before
it enters admission state. There is no runtime Patrol Fix migration, cutover,
or dual-write subsystem.

## Backlinks

- [[modules/patrol]] · [[modules/daemon]] · [[state-model]]

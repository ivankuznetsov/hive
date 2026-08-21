---
title: hive patrol
type: command
source: lib/hive/commands/patrol.rb, lib/hive/patrol/*
created: 2026-05-28
updated: 2026-08-21
tags: [command, patrol, review, findings]
---

**TLDR**: `hive patrol` is a discovery command. It reviews a clean snapshot of
the registered project's default branch, records accepted findings under
`.hive-state/patrol/`, and publishes them to the shared Patrol Fix admission
outbox. It does not edit code, create worktrees, push branches, open pull
requests, or create review tasks.

## Usage

```bash
hive patrol my-project
hive patrol my-project --dry-run
hive patrol my-project --json
hive patrol my-project --list
hive patrol my-project --list --json
```

The project must be registered, use the `coding` default workflow, and have
Patrol enabled. `--list` reads the bounded finding projection without starting
a review. `--dry-run` maps and reviews but does not persist findings, cursors,
or outbox entries.

## Discovery lifecycle

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
6. Persist each newly active finding and publish its immutable candidate
   snapshot directly to the Patrol Fix source outbox.
7. Update the feature cursor and `last_scanned_sha` only when the corresponding
   review scope completed cleanly, then rebuild the bounded query projection.

The downstream `patrol-fix` workflow owns admission, implementation,
validation, review, and publication. Discovery has no publication policy or
GitHub mutation capability.

## Output

`--json` emits `hive-patrol.v3`. Its historical delivery fields remain present
for schema compatibility but are fixed to the discovery-only values:

```json
{
  "schema": "hive-patrol",
  "schema_version": 3,
  "ok": true,
  "project": "my-project",
  "dry_run": false,
  "findings": 2,
  "fix_candidates": 2,
  "fixes_attempted": 0,
  "fixes_validated": 0,
  "prs_opened": 0,
  "pr_urls": [],
  "review_handoff_errors": [],
  "fix_results": []
}
```

`--list --json` emits `hive-patrol-findings.v1` with at most 25 active-first,
newest-first summaries. Full evidence remains in the authoritative finding
store.

## Scheduling and migration

`Hive::Daemon::PatrolScheduler` decides when ordinary discovery is due and
dispatches this command. The source outbox is drained independently by
`Hive::Daemon::PatrolFixAdmissionScheduler`; discovery allowance and workflow
capacity are separate concerns.

Historical local findings can be imported once with
`script/migrate_patrol_findings.rb`. There is no runtime Patrol Fix migration,
cutover, or dual-write subsystem.

## Backlinks

- [[modules/patrol]] · [[modules/daemon]] · [[state-model]]

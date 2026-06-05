---
title: hive patrol
type: command
source: lib/hive/commands/patrol.rb, lib/hive/patrol/*
created: 2026-05-28
updated: 2026-05-28
tags: [command, patrol, review, pr, json]
---

**TLDR**: `hive patrol PROJECT [--dry-run] [--json]` runs one clawpatch-style repository scan cycle for a registered project: map semantic feature slices, review each slice, attempt isolated fixes above the confidence gate, validate configured commands, and open PRs for validated fixes only. Patrol state lives under `<project>/.hive-state/patrol/`; findings never go through `1-inbox/` or the stage pipeline.

## Usage

```bash
hive patrol my-project
hive patrol my-project --dry-run
hive patrol my-project --json
```

`PROJECT` is a registered project name from the global config. The project must opt in through `<project>/.hive-state/config.yml`:

```yaml
patrol:
  enabled: true
  trigger: continuous
  agent: claude
  min_confidence_to_fix: medium
  max_prs_per_cycle: 3
  draft_prs: false   # default: open ready PRs (the babysitter skips drafts). Set true to open draft PRs.
  commands:
    test: bundle exec rake test
```

`patrol.trigger` accepts three modes:

- `new_commits` runs only when the default branch SHA differs from `last_scanned_sha`.
- `timer` runs whenever `last_run_at` is older than `poll_interval_sec`.
- `continuous` is the hybrid mode for larger repos: it runs when either the default branch moved or the timer interval elapsed, so patrol can keep mining existing slices between merges while still reacting to fresh `main` changes.

## Steps

1. Reconcile dismissal memory for existing patrol branches and PRs.
2. Map tracked repository files into durable feature records under `.hive-state/patrol/features/`.
3. Ask the configured agent to emit schema-shaped findings for each feature.
4. Skip dismissed, already-PR'd, low-confidence, and low-severity findings.
5. For each remaining finding (in order), create a dedicated `hive-patrol/...` worktree branch and run the fix agent. `max_prs_per_cycle` caps the number of PRs **opened** per scan, not the number of fix candidates: the loop keeps attempting candidates until that many PRs have actually opened, so a failed validation does not waste the budget on an otherwise-fixable later finding.
6. Run configured validation commands in the fix worktree.
7. Open a PR only when validation passed and the diff is not blocked by the secret scanner.
8. Update `.hive-state/patrol/state.json` with `last_run_at` and `last_scanned_sha`.

`--dry-run` stops after map + review + candidate selection. It updates scan state but does not create fix worktrees, push branches, or open PRs.

## JSON

With `--json`, the command emits a single `hive-patrol.v1` envelope:

```json
{
  "schema": "hive-patrol",
  "schema_version": 1,
  "ok": true,
  "project": "my-project",
  "project_root": "/home/me/Dev/my-project",
  "dry_run": false,
  "features_mapped": 4,
  "findings": 2,
  "fix_candidates": 1,
  "fixes_attempted": 1,
  "fixes_validated": 1,
  "prs_opened": 1,
  "pr_urls": ["https://github.com/org/repo/pull/123"],
  "skipped_findings": [],
  "last_scanned_sha": "abc123"
}
```

Config errors emit `ok: false`, `error_kind: "config"`, and exit 78.

## Daemon

The always-on behavior comes from [[modules/daemon]]: `Hive::Daemon::PatrolScheduler` checks opt-in projects on a slow cadence and returns `hive patrol <project> --json` dispatches. The dispatcher still applies `daemon.enabled`, legacy-layout, dry-run, and concurrency gates before spawning the child.

## Backlinks

- [[modules/patrol]]
- [[modules/daemon]]
- [[modules/config]]
- [[cli]]

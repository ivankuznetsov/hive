---
title: hive refactor-patrol
type: command
source: lib/hive/commands/refactor_patrol.rb, lib/hive/refactor_patrol/*
created: 2026-07-02
updated: 2026-07-15
tags: [command, refactor-patrol, architecture, post-merge, json]
---

**TLDR**: `hive refactor-patrol PROJECT [--dry-run] [--json]` is the
reporting-only sibling of [[commands/patrol]]. It maps patrol feature slices,
asks an agent for evidence-backed architecture refactor theses, scores them by
transparent leverage signals, flags scope and guardrail risk, and emits a
ranked `hive-refactor-patrol.v1` report. v1 never edits worktrees, opens PRs,
or creates `6-review` tasks.

## Usage

```bash
hive refactor-patrol my-project
hive refactor-patrol my-project --dry-run
hive refactor-patrol my-project --json
hive refactor-patrol my-project --feature route-home --changed-since origin/master
hive refactor-patrol my-project --changed-since HEAD~1 --path lib/hive --path test/unit
```

The project must opt in through `<project>/.hive-state/config.yml`:

```yaml
refactor_patrol:
  enabled: true
  agent: claude
  min_confidence: medium
  commands:
    test: bundle exec rake test
```

Refactor-patrol has no independent trigger or mode knobs. It remains available
on demand, and the daemon can also invoke it for post-merge follow-up only when
the existing patrol scheduler decides a normal patrol cycle is due. Both
`patrol.enabled` and `refactor_patrol.enabled` must be true; there is no second
timer, merge watcher, or always-on architecture queue.

## Pipeline

1. Load the registered project and require `refactor_patrol.enabled: true`.
2. Reuse `Hive::Patrol::Mapper` to map feature slices, with
   `refactor_patrol.include`, `exclude`, and review caps projected into the
   mapper-compatible patrol config.
3. Apply scope hints with precedence `--feature`, then `--entrypoint`, then
   repeated `--path` values. Multiple paths filter by union. `--changed-since`
   narrows a scoped run to changed owned files; on its own it boosts changed
   features while still allowing full discovery.
4. Compute leverage signals through `Hive::RefactorPatrol::Leverage`: churn,
   fan-in, size/complexity, and cross-boundary coupling. The score always
   carries a per-signal breakdown.
5. Ask `Hive::RefactorPatrol::Reviewer` for schema-shaped theses using
   `templates/refactor_patrol_review_prompt.md.erb`.
6. Validate each thesis against `hive-refactor-patrol-thesis.v1`, stamp a
   refactor-patrol fingerprint, enforce admissibility, and require behavior
   preservation guidance.
7. Run `Hive::RefactorPatrol::Caps` to flag cap breaches, declared public-API
   impact, cross-feature impact, and dependency-bump risk. Refactoring
   preserves the public contract by definition, so merely working inside
   public-surface files (`bin/`, `cli.rb`, `schemas/`) is a non-blocking
   `touches_public_api_surface` advisory, not a flag — only an agent-declared
   contract change flags `public_api_impact`.
8. Run `Hive::RefactorPatrol::Collisions` to suppress already-seen/dismissed
   refactor theses and flag open patrol activity on the same slice.
9. Persist under `.hive-state/refactor_patrol/` unless `--dry-run`, and emit
   text or JSON through `Hive::RefactorPatrol::Reporter`.

## Scheduled post-merge follow-up

`Hive::Daemon::PatrolScheduler` owns the automatic path. A normal patrol due
decision first preserves the ordinary `hive patrol` dispatch, then opens or
extends one architecture batch pinned to the registered trunk HEAD. First
enablement seeds that healthy HEAD as a non-retroactive checkpoint. An open
batch can drain on later daemon ticks, oldest PR first, but newer merges are not
discovered until another normal patrol due decision.

Discovery is local and offline. Hive walks first-parent history from the
checkpoint to the pinned head and attributes only subjects ending in `(#123)`
or standard `Merge pull request #123` subjects. Each attributed PR gets a
separate child whose `--changed-since` value is that merge commit's first
parent. Unattributed commits are retained as diagnostics rather than guessed or
looked up through GitHub.

Every child analyzes the exact registered default-branch checkout. Before
dispatch, Hive requires the local `bin/hive` capability, a clean symbolic
default branch, HEAD equality with the local branch and any configured cached
`origin/<default_branch>` ref, no Git operation sentinel, and a nonblocking
architecture lock. Hive never fetches, pulls, switches, resets, cleans, or uses
a task/PR worktree. The retryable reasons include `capability_missing`,
`capability_unrunnable`, `checkout_missing`, `checkout_detached`,
`checkout_wrong_branch`, `checkout_dirty`, `checkout_stale`,
`checkout_operation_in_progress`, `checkout_busy`, `checkout_moved`, and
`scope_unusable`.

Scope is selected in the order one owning feature, one owning entrypoint, then
stable changed-root paths. Multi-feature or low-confidence ownership uses the
same bounded changed roots and is labeled as fallback. Hive refuses empty,
unsafe, or repository-root scope instead of launching a whole-repository scan.

## State

Refactor-patrol state is independent from patrol:

- `.hive-state/refactor_patrol/features/`
- `.hive-state/refactor_patrol/theses/`
- `.hive-state/refactor_patrol/runs/`
- `.hive-state/refactor_patrol/state.json`
- `.hive-state/refactor_patrol/fingerprints.json`
- `.hive-state/refactor_patrol/dismissed.json`
- `.hive-state/refactor_patrol/post_merge/state.json`
- `.hive-state/refactor_patrol/post_merge/emissions.json`
- `.hive-state/refactor_patrol/post_merge/reports/pr-<number>-<merge-sha>.json`

It reads patrol fingerprints only as read-only collision awareness. It does not
mutate patrol state and does not share patrol dismissal memory.

The `post_merge/` subtree is also independent from ordinary patrol. Its state
tracks the initialization SHA, active batch head, contiguous successful
checkpoint, per-merge attempts, and the first logical attempt's fingerprint
snapshot. Reports validate against `hive-refactor-patrol-post-merge.v1` and
carry PR/base/merge attribution, chosen scope, separate accepted/flagged/
suppressed totals, actionable flagged-thesis detail, and an `emitted_delta` of
new or changed fingerprint/content identities. Report and emission ledger
writes happen before a PR becomes processed, so interruption leaves it owed and
durable artifacts can be reconciled without rerunning or re-emitting.

## JSON

With `--json`, the command emits a `hive-refactor-patrol.v1` success or error
envelope. Success payloads include `features_mapped`, accepted thesis count,
`ranked`, `flagged_theses`, `suppressed`, and `last_scanned_sha`. Each durable
thesis validates against `hive-refactor-patrol-thesis.v1`.

## Backlinks

- [[commands/patrol]]
- [[modules/config]]
- [[cli]]

---
title: hive refactor-patrol
type: command
source: lib/hive/commands/refactor_patrol.rb, lib/hive/refactor_patrol/*
created: 2026-07-02
updated: 2026-07-02
tags: [command, refactor-patrol, architecture, json]
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

Unlike patrol, refactor-patrol has no trigger/mode scheduling knobs in v1. It
is on-demand only.

## Pipeline

1. Load the registered project and require `refactor_patrol.enabled: true`.
2. Reuse `Hive::Patrol::Mapper` to map feature slices, with
   `refactor_patrol.include`, `exclude`, and review caps projected into the
   mapper-compatible patrol config.
3. Apply scope hints with precedence `--feature`, then `--entrypoint`, then
   `--path`. `--changed-since` narrows a scoped run to changed owned files; on
   its own it boosts changed features while still allowing full discovery.
4. Compute leverage signals through `Hive::RefactorPatrol::Leverage`: churn,
   fan-in, size/complexity, and cross-boundary coupling. The score always
   carries a per-signal breakdown.
5. Ask `Hive::RefactorPatrol::Reviewer` for schema-shaped theses using
   `templates/refactor_patrol_review_prompt.md.erb`.
6. Validate each thesis against `hive-refactor-patrol-thesis.v1`, stamp a
   refactor-patrol fingerprint, enforce admissibility, and require behavior
   preservation guidance.
7. Run `Hive::RefactorPatrol::Caps` to flag cap breaches, public API surfaces,
   cross-feature impact, and dependency-bump risk.
8. Run `Hive::RefactorPatrol::Collisions` to suppress already-seen/dismissed
   refactor theses and flag open patrol activity on the same slice.
9. Persist under `.hive-state/refactor_patrol/` unless `--dry-run`, and emit
   text or JSON through `Hive::RefactorPatrol::Reporter`.

## State

Refactor-patrol state is independent from patrol:

- `.hive-state/refactor_patrol/features/`
- `.hive-state/refactor_patrol/theses/`
- `.hive-state/refactor_patrol/runs/`
- `.hive-state/refactor_patrol/state.json`
- `.hive-state/refactor_patrol/fingerprints.json`
- `.hive-state/refactor_patrol/dismissed.json`

It reads patrol fingerprints only as read-only collision awareness. It does not
mutate patrol state and does not share patrol dismissal memory.

## JSON

With `--json`, the command emits a `hive-refactor-patrol.v1` success or error
envelope. Success payloads include `features_mapped`, accepted thesis count,
`ranked`, `flagged_theses`, `suppressed`, and `last_scanned_sha`. Each durable
thesis validates against `hive-refactor-patrol-thesis.v1`.

## Backlinks

- [[commands/patrol]]
- [[modules/config]]
- [[cli]]

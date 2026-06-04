---
title: Hive::Patrol
type: module
source: lib/hive/patrol/
created: 2026-05-28
updated: 2026-05-28
tags: [module, patrol, review, worktree, pr]
---

**TLDR**: `Hive::Patrol::*` is the repository-patrol engine behind [[commands/patrol]]. It keeps clawpatch-style work units and audit state as plain JSON under `.hive-state/patrol/`, delegates review/fix reasoning to configured Hive agent profiles, validates fixes in isolated worktrees, and surfaces successful results only as PRs.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Patrol::Mapper` | `lib/hive/patrol/mapper.rb` | Scans tracked files and manifests for route, command, package, and test-suite feature slices. Persists feature JSON. |
| `Hive::Patrol::Feature` | `lib/hive/patrol/feature.rb` | Durable feature record: `id`, `kind`, `entrypoints`, `owned_files`, `context_files`, and `tests`. |
| `Hive::Patrol::Reviewer` | `lib/hive/patrol/reviewer.rb` | Renders `templates/patrol_review_prompt.md.erb`, runs the configured agent, validates finding categories/severities/confidences, and persists finding JSON. |
| `Hive::Patrol::Finding` | `lib/hive/patrol/finding.rb` | Durable finding record linked to a feature and optional fingerprint. |
| `Hive::Patrol::Fingerprint` | `lib/hive/patrol/fingerprint.rb` | Stable SHA-256 identity for dedup and dismissal checks. Anchors on feature, category, normalized file path, and code snippet rather than raw line number. |
| `Hive::Patrol::Fixer` | `lib/hive/patrol/fixer.rb` | Creates a dedicated worktree branch, runs the fix agent, validates, commits passing changes, records patch attempts, and removes failed worktrees. |
| `Hive::Patrol::Validator` | `lib/hive/patrol/validator.rb` | Runs operator-configured validation commands in the fix worktree. No commands means not validatable, so no PR. |
| `Hive::Patrol::PrOpener` | `lib/hive/patrol/pr_opener.rb` | Secret-scans, pushes the patrol branch, opens a ready (non-draft) PR by default — `patrol.draft_prs: true` reverts to draft — and records fingerprint-to-PR state. |
| `Hive::Patrol::Dismissals` | `lib/hive/patrol/dismissals.rb` | Reconciles closed-unmerged patrol PRs into `dismissed.json` so the same finding is not immediately re-filed. |
| `Hive::Patrol::StateStore` | `lib/hive/patrol/state_store.rb` | Creates and atomically writes the `.hive-state/patrol/` JSON tree. |

## State

Patrol state is deliberately inspectable and removable:

```text
.hive-state/patrol/
  features/*.json
  findings/*.json
  patches/*.json
  runs/*/
  state.json
  fingerprints.json
  dismissed.json
```

The managed repository worktree is not edited by fixes. `Fixer` uses [[modules/worktree]] to create a branch named `hive-patrol/<feature-id>-<fingerprint8>` under the project's worktree root.

## Safety invariants

- Patrol is opt-in: `patrol.enabled` defaults false and the daemon still requires `daemon.enabled`.
- Findings surface only as PRs; no stage folder or `1-inbox/` output is written.
- PR creation is gated on validation passing and on the secret scanner.
- Each finding fingerprint maps to at most one active or merged PR.
- Closed-unmerged patrol PRs become dismissals and are skipped on future cycles.
- Agent prompts treat findings and recommendations as data; validation commands come only from project config.

## Backlinks

- [[commands/patrol]]
- [[modules/daemon]]
- [[modules/config]]
- [[modules/worktree]]
- [[modules/agent]]

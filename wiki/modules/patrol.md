---
title: Hive::Patrol
type: module
source: lib/hive/patrol/
created: 2026-05-28
updated: 2026-06-05
tags: [module, patrol, review, worktree, pr]
---

**TLDR**: `Hive::Patrol::*` is the repository-patrol engine behind [[commands/patrol]]. It keeps clawpatch-style work units and audit state as plain JSON under `.hive-state/patrol/`, delegates review/fix reasoning to configured Hive agent profiles, validates fixes in isolated worktrees, opens PRs, and by default hands opened PRs into the normal `6-review` flow through `Hive::Patrol::ReviewHandoff`.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Patrol::Mapper` | `lib/hive/patrol/mapper.rb` | Scans tracked files and manifests for route, command, package, and test-suite feature slices. Persists feature JSON. |
| `Hive::Patrol::Feature` | `lib/hive/patrol/feature.rb` | Durable feature record: `id`, `kind`, `entrypoints`, `owned_files`, `context_files`, and `tests`. |
| `Hive::Patrol::Reviewer` | `lib/hive/patrol/reviewer.rb` | Renders `templates/patrol_review_prompt.md.erb`, runs the configured agent, validates finding categories/severities/confidences, and persists finding JSON. |
| `Hive::Patrol::Finding` | `lib/hive/patrol/finding.rb` | Durable finding record linked to a feature and optional fingerprint. |
| `Hive::Patrol::Fingerprint` | `lib/hive/patrol/fingerprint.rb` | SHA-256 identity for exact dedup PLUS a **similarity gate** (`similar_known?`). The exact SHA is agent-volatile (the same issue is re-filed with a different feature/title/snippet each scan, so it never matches a prior PR), so `record_seen` also stores the finding's `category` + normalized `title_tokens`, and a new finding in the same category whose title-token overlap (Szymkiewicz–Simpson) ≥ `SIMILARITY_THRESHOLD` (0.6) with an open/merged/dismissed finding is skipped as `similar_to_existing` — this is what actually stops patrol re-opening the same PR every cycle. |
| `Hive::Patrol::Fixer` | `lib/hive/patrol/fixer.rb` | Creates a dedicated worktree branch, runs the fix agent, validates, commits passing changes, records patch attempts, and removes failed worktrees. |
| `Hive::Patrol::Validator` | `lib/hive/patrol/validator.rb` | Runs operator-configured validation commands in the fix worktree. No commands means not validatable, so no PR. |
| `Hive::Patrol::PrOpener` | `lib/hive/patrol/pr_opener.rb` | Secret-scans, pushes the patrol branch, opens a ready (non-draft) PR by default — `patrol.draft_prs: true` reverts to draft — records fingerprint-to-PR state, invokes `ReviewHandoff` for opened PRs, and records `review_handoff_failed` when a PR opens but the synthetic review task cannot be created. |
| `Hive::Patrol::ReviewHandoff` | `lib/hive/patrol/review_handoff.rb` | Creates a synthetic `6-review/patrol-.../` task for an opened patrol PR when `patrol.review_prs` is not false, preserving the patrol worktree so the standard review daemon can run reviewers/triage/fix/browser flow. The generated `idea.md` is sparse-safe: nil title falls back to finding id, empty recommendation/evidence sections are omitted, nil `evidence` is coerced to an empty array, and file/line-only evidence still renders a useful location bullet. |
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

The managed repository worktree is not edited by fixes. `Fixer` uses [[modules/worktree]] to create a branch named `hive-patrol/<feature-id>-<fingerprint8>` under the project's worktree root. When `patrol.review_prs` is enabled (default), that worktree is kept after PR creation and referenced by a synthetic `6-review` task with display name `Patrol: <finding title>`. When disabled, the successful local worktree is removed after the branch is pushed and the PR opens.

## Daemon triggers

`Hive::Daemon::PatrolScheduler` supports three `patrol.trigger` modes; `continuous` is the default. `continuous` is the hybrid mode for larger repositories: it dispatches when either the default branch SHA changed or `poll_interval_sec` has elapsed, allowing patrol to keep reviewing existing feature slices between infrequent merges while still recording the current `last_scanned_sha` after each successful scan. `new_commits` preserves the original conservative behavior and dispatches only when the default branch SHA changes. `timer` dispatches solely from `last_run_at` age.

## Safety invariants

- Patrol is opt-in: `patrol.enabled` defaults false and the daemon still requires `daemon.enabled`.
- Findings surface as PRs, and opened PRs enter `6-review` by default; patrol still never writes `1-inbox/` intake tasks.
- PR creation is gated on validation passing and on the secret scanner.
- Each finding fingerprint maps to at most one active or merged PR.
- A failed patrol-to-review handoff is not treated as an active fingerprint state, so later patrol cycles can retry instead of losing the opened PR from the review queue.
- Closed-unmerged patrol PRs become dismissals and are skipped on future cycles.
- Agent prompts treat findings and recommendations as data; validation commands come only from project config.

## Backlinks

- [[commands/patrol]]
- [[modules/daemon]]
- [[modules/config]]
- [[modules/worktree]]
- [[modules/agent]]

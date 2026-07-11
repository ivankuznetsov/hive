---
title: Hive::Patrol
type: module
source: lib/hive/patrol/
created: 2026-05-28
updated: 2026-07-11
tags: [module, patrol, review, worktree, pr, codex]
---

**TLDR**: `Hive::Patrol::*` is the ordinary repository-patrol engine behind [[commands/patrol]]. It keeps clawpatch-style work units and audit state as plain JSON under `.hive-state/patrol/`, delegates review/fix reasoning to configured Hive agent profiles, records patrol review/fix token usage in `Hive::UsageDb`, validates fixes in isolated worktrees, opens PRs, and by default hands opened PRs into the normal `6-review` flow through `Hive::Patrol::ReviewHandoff`. The separately configured, post-merge architecture patrol lives under `Hive::RefactorPatrol::*`; the two schedulers share a scan budget but not state, mapping, policy, or action ledgers.

## Module map

| Module | File | Purpose |
|--------|------|---------|
| `Hive::Patrol::Mapper` | `lib/hive/patrol/mapper.rb` | Scans tracked files and manifests for route, command, package, and test-suite feature slices. Persists feature JSON. |
| `Hive::Patrol::Feature` | `lib/hive/patrol/feature.rb` | Durable feature record: `id`, `kind`, `entrypoints`, `owned_files`, `context_files`, and `tests`. |
| `Hive::Patrol::Reviewer` | `lib/hive/patrol/reviewer.rb` | Renders `templates/patrol_review_prompt.md.erb`, runs the configured agent, records `patrol-review` usage rows when agent usage is present, validates finding categories/severities/confidences, and persists finding JSON. |
| `Hive::Patrol::Finding` | `lib/hive/patrol/finding.rb` | Durable finding record linked to a feature and optional fingerprint. |
| `Hive::Patrol::Fingerprint` | `lib/hive/patrol/fingerprint.rb` | SHA-256 identity for exact dedup PLUS a **similarity gate** (`similar_known?`). The exact SHA is agent-volatile (the same issue is re-filed with a different feature/title/snippet each scan, so it never matches a prior PR), so `record_seen` also stores the finding's `category` + normalized `title_tokens`, and a new finding in the same category whose title-token overlap (Szymkiewicz–Simpson) ≥ `SIMILARITY_THRESHOLD` (0.6) with an open/merged/dismissed finding is skipped as `similar_to_existing` — this is what actually stops patrol re-opening the same PR every cycle. |
| `Hive::Patrol::Fixer` | `lib/hive/patrol/fixer.rb` | Creates a dedicated worktree branch, runs the fix agent, records `patrol-fix` usage rows when agent usage is present, validates, commits passing changes, records patch attempts, and removes failed worktrees. |
| `Hive::Patrol::Validator` | `lib/hive/patrol/validator.rb` | Runs operator-configured validation commands in the fix worktree. No commands means not validatable, so no PR. |
| `Hive::Patrol::PrOpener` | `lib/hive/patrol/pr_opener.rb` | Secret-scans, pushes the patrol branch, opens a ready (non-draft) PR by default — `patrol.draft_prs: true` reverts to draft — records fingerprint-to-PR state, invokes `ReviewHandoff` for opened PRs, and records `review_handoff_failed` when a PR opens but the synthetic review task cannot be created. |
| `Hive::Patrol::ReviewHandoff` | `lib/hive/patrol/review_handoff.rb` | Creates a synthetic `6-review/patrol-.../` task for an opened patrol PR when `patrol.review_prs` is not false, preserving the patrol worktree so the standard review daemon can run reviewers/triage/fix/browser flow. |
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

## Patrol PR reviewer (cheap by default)

Patrol PRs flow into `6-review` and are reviewed by `patrol.review.reviewers` (a separate set from human PRs' `review.reviewers`) — see [[stages/review]] `run_reviewers` → `patrol_task?` routing. Because patrol opens many PRs per cycle, the **DEFAULT patrol reviewer is the native single-pass `codex review`** adapter (`kind: codex_review`, `name: codex-native-review`), not the multi-persona `ce-code-review` fan-out (6–18 subagents). It runs one tuned, read-only `codex review` and captures stdout into the GFM-checkbox findings file the triage/fix loop already consumes, so the loop is unchanged. See [[modules/reviewers]] `Reviewers::CodexReview` for argv/format details. Operators can override `patrol.review.reviewers` per project to add the ce-code-review fan-out or Claude.

## Ordinary patrol versus architecture patrol

Ordinary patrol scans the current repository into route, command, package, and
test-suite features, then attempts finding-sized fixes. Architecture patrol
([[commands/refactor-patrol]]) is triggered by an immutable merged-PR
occurrence, maps language-neutral feature and documentation slices from that
merge, and requires every architectural thesis to receive a durable accepted,
flagged, or suppressed disposition before any separately authorized action.

The two systems deliberately retain separate namespaces:
`.hive-state/patrol/` for ordinary patrol and
`.hive-state/refactor_patrol/v2/` for architecture manifests, jobs, semantic
families, indexes, and result receipts. `Hive::Daemon::PatrolArbiter` is the
only shared orchestration seam: it alternates ready work under the project's
`daemon.max_concurrent_patrol_scans` capacity. Enabling architecture discovery
does not enable ordinary patrol, auto-fixing, or issue filing, and neither
system can consume the other's state as proof of completion.

## Daemon triggers

Patrol is **opt-in**. A project with **no patrol section at all** (or a patrol section that omits `mode:`) resolves to `enabled: false` — [[modules/config]] only derives mode knobs when `mode:` is **explicitly present** in the raw config. `medium` is the default offered by the `hive init` *prompt* (which writes an explicit `mode: "medium"` into the rendered template), never a config-resolution default, so legacy projects without a patrol block are never silently enabled.

Operators normally configure scheduling through `patrol.mode`, which [[modules/config]] resolves into `enabled`, `trigger`, and `poll_interval_sec` before the daemon sees the project config. An explicit `ultrapatrol`, `high`, or `medium` dispatches on a timer every 30 minutes, 2 hours, and 4 hours respectively (all set `enabled: true`); `low` uses `trigger: new_commits` and keeps the cheap 600-second SHA-check cadence; `off` resolves to `enabled: false`. The mode never changes finding/PR caps or the confidence gate. Explicit granular knobs (e.g. `enabled: true` or `poll_interval_sec:`) always win over a set mode and survive the deep-merge even when no `mode:` is set.

`Hive::Daemon::PatrolScheduler` still consumes the lower-level `patrol.trigger` modes. `continuous` dispatches when either the default branch SHA changed or `poll_interval_sec` has elapsed, allowing patrol to keep reviewing existing feature slices between infrequent merges while still recording the current `last_scanned_sha` after each successful scan. `new_commits` dispatches only when the default branch SHA changes. `timer` dispatches solely from `last_run_at` age.

## Safety invariants

- Patrol is opt-in at the scheduler gate AND at config resolution: a missing patrol section, a missing `mode:`, `patrol.mode: off`, or `patrol.enabled: false` all leave patrol disabled and prevent daemon dispatch, and the daemon still requires `daemon.enabled`.
- Findings surface as PRs, and opened PRs enter `6-review` by default; patrol still never writes `1-inbox/` intake tasks.
- PR creation is gated on validation passing and on the secret scanner.
- Each finding fingerprint maps to at most one active or merged PR.
- A failed patrol-to-review handoff is not treated as an active fingerprint state, so later patrol cycles can retry instead of losing the opened PR from the review queue.
- Closed-unmerged patrol PRs become dismissals and are skipped on future cycles.
- Agent prompts treat findings and recommendations as data; validation commands come only from project config.

## Backlinks

- [[commands/patrol]]
- [[commands/refactor-patrol]]
- [[modules/daemon]]
- [[modules/config]]
- [[modules/worktree]]
- [[modules/agent]]

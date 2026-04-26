---
title: 5-review stage
type: stage
source: lib/hive/stages/review.rb, lib/hive/stages/review/{ci_fix,triage,browser_test,fix_guardrail}.rb, templates/{fix,ci_fix,browser_test,triage_*}*.erb
created: 2026-04-26
updated: 2026-04-26
tags: [stage, review, autonomous-loop, ci, triage, fix-guardrail]
---

**TLDR**: The autonomous review loop. After 4-execute commits the implementation, the user `mv`s the task to `5-review/`. `Hive::Stages::Review.run!` runs CI on entry, then loops `reviewers → triage → fix` until the branch is clean (or hits a budget cap) and finalises with a browser-test phase. One `hive run` either lands a terminal marker (`REVIEW_COMPLETE`, `REVIEW_WAITING`, `REVIEW_CI_STALE`, `REVIEW_STALE`, `REVIEW_ERROR`) or exhausts per-spawn budgets — never an in-progress state the user has to reconcile.

## Setup

- **State file**: `task.md` with the same frontmatter that 4-execute wrote (`slug`, `started_at`). The runner does NOT track pass count in frontmatter — it derives the current pass by reading `reviews/<reviewer-name>-<NN>.md` filenames and taking the maximum NN.
- **Worktree pointer**: `worktree.yml` (carried over from 4-execute; missing → exit 1 with "5-review entered without a worktree.yml").
- **Reviews directory**: `reviews/` (carried over). New per-pass files written here: `<reviewer>-NN.md`, `escalations-NN.md`, `ci-blocked.md` (Phase 1 hard-block), `browser-blocked-NN.md` (Phase 5 warned), `fix-guardrail-NN.md` (post-fix tripped).

## Pre-flight (`Review.run!`)

| Marker / State | Action |
|----------------|--------|
| `:review_complete` | print "already complete; mv this folder to 6-pr/", return |
| `:review_ci_stale` | warn; user fixes CI, removes marker, re-runs |
| `:review_stale` | warn; user trims `reviews/` and removes marker |
| `:review_error` | warn with attrs; user investigates, clears marker |
| `:review_waiting` | resume — skip Phase 2/3, jump straight to Phase 4 with the user's manually-ticked `[x]` marks |
| no `worktree.yml` | exit 1 (must come from 4-execute) |
| `worktree.yml` points at deleted path | exit 1 with `git worktree prune` recovery hint |

## The pass loop

```
Phase 1 (CI fix)         once on entry
Phase 2 (reviewers)      sequential, one adapter per spec in cfg.review.reviewers
Phase 3 (triage)         courageous (default) | safetyist | review.triage.custom_prompt
branch on triage:
  any [x]                → Phase 4 (fix) → loop to Phase 2 with pass++
  escalations only       → REVIEW_WAITING escalations=N pass=NN (terminal)
  all clean              → Phase 5 (browser test) → REVIEW_COMPLETE
```

Pass cap (`review.max_passes`, default 4) gates re-entry to Phase 2 — exceeding it sets `REVIEW_STALE pass=NN`. Wall-clock cap (`review.max_wall_clock_sec`, default 5400) is checked at every phase boundary; exceeding it sets `REVIEW_STALE reason=wall_clock`.

## Phase 1 — CI fix (`Hive::Stages::Review::CiFix`)

Runs `cfg.review.ci.command` (e.g., `bin/ci`) once on entry. On red, captures combined stdout+stderr, strips ANSI colour codes, tail-truncates to the configured line cap, byte-caps to 256 KB, and feeds the failure log to a fix agent through the per-spawn `<user_supplied>` nonce wrapper. Re-runs CI. Up to `review.ci.max_attempts` (default 3); cap reached → `:stale` → runner writes `reviews/ci-blocked.md` and sets `REVIEW_CI_STALE`. Reviewers do NOT run on red CI.

`review.ci.command` is project-specific by design — hive doesn't ship a Rubocop/Brakeman driver because that would couple the orchestrator to one ecosystem. The user owns the contract; hive shells out and parses exit code + last-N lines.

## Phase 2 — reviewers (`Hive::Reviewers::Agent`)

For each spec in `cfg.review.reviewers`, sequentially: dispatch via `Hive::Reviewers.dispatch(spec, ctx)`, run through `Hive::Agent.run!` with the spec's profile, write `reviews/<output_basename>-<NN>.md`. Per-reviewer failure → stub finding file (`- [ ] reviewer "name" failed: <error>`) so triage can still see it; the loop continues. All reviewers fail → `REVIEW_ERROR phase=reviewers reason=all_failed`. Empty reviewer list → skip directly to the all-clean branch (Phase 5).

CE skill invocation is profile-aware: `templates/reviewer_claude_ce_code_review.md.erb` and `templates/reviewer_codex_ce_code_review.md.erb` invoke the same logical CE skill (`/compound-engineering:ce-code-review`) but render the call syntax according to `profile.skill_syntax_format`. `templates/reviewer_pr_review_toolkit.md.erb` is a stand-in for the `pr-review-toolkit:code-reviewer` agent.

Reviewer kind `linter` is rejected with a helpful pointer to `review.ci.command` — linters belong in the project's CI driver, not in hive's reviewer adapter (see ADR-014).

## Phase 3 — triage (`Hive::Stages::Review::Triage`)

Spawns a triage agent with all per-reviewer files for the current pass concatenated through the per-spawn nonce wrapper. The agent's job: tick `[x]` on findings safe to auto-fix; leave `[ ]` (with a one-line rationale appended) on findings that need human review. Two bias presets:

- **`courageous`** (default, `templates/triage_courageous.md.erb`) — apply max review fixes in automatic mode; escalate only sketchy / architecture-level findings.
- **`safetyist`** (opt-in, `templates/triage_safetyist.md.erb`) — escalate when in doubt; only tick obvious mechanical fixes.

`review.triage.custom_prompt` overrides both presets with a path under `templates/`. Path-escape-guarded — `..` and absolute paths are rejected before render.

Plan / worktree.yml / task.md are SHA-256 protected around the triage spawn (ADR-013); tampering yields `REVIEW_ERROR phase=triage reason=triage_tampered`.

Escalations land in `reviews/escalations-<NN>.md` — every line that triage left as `[ ]` gets copied here as a digest for the user.

## Branching after triage

- `accepted.empty? && escalations.zero?` — Phase 2 produced zero findings — jump to Phase 5 (browser test).
- `accepted.empty? && escalations > 0` — Pause for user gate: `REVIEW_WAITING escalations=N pass=NN`. The user ticks `[x]` on whatever escalations they want fixed and re-runs; the runner detects `:review_waiting` resume, skips Phase 2/3, jumps to Phase 4.
- `accepted.any?` — Run Phase 4.

## Phase 4 — fix (`spawn_fix_agent`)

Spawns the fix agent (`cfg.review.fix.agent`, default `claude`) with the concatenated `[x]` lines from every per-reviewer file for the current pass, wrapped in the `<user_supplied>` nonce. The fix prompt requires git trailers on every commit (`Hive-Task-Slug`, `Hive-Fix-Pass`, `Hive-Fix-Findings`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase: fix`) — consumed by `hive metrics rollback-rate` (U14).

Plan / worktree.yml / task.md are SHA-256 protected around the fix spawn; tampering → `REVIEW_ERROR phase=fix reason=fix_tampered`.

After the fix agent returns, `Hive::Stages::Review::FixGuardrail.run!` (ADR-020 / U13) takes `git diff base..head` of the new commits and walks it once, dispatching each line to the configured pattern set:

- `shell_pipe_to_interpreter` — curl/wget pipe into sh/bash/python/ruby/node
- `ci_workflow_edit` — `.github/workflows/`, gitlab-ci, circleci, Jenkinsfile, bitbucket-pipelines, azure-pipelines, travis
- `secrets_pattern_match` — dispatches to `Hive::SecretPatterns.scan` (AWS, GitHub, OpenAI, Anthropic, Stripe, Slack, JWT, PEM, generic api_key)
- `dotenv_edit` — `.env*`, `secrets.yml`, `credentials.yml`, `.npmrc`, `.pypirc`
- `dependency_lockfile_change` — Gemfile.lock, package-lock.json, pnpm-lock, yarn.lock, Cargo.lock, go.sum, poetry.lock, Pipfile.lock, composer.lock, uv.lock
- `permission_change` — `new mode 100755` raw-diff-header

Per-project override via `review.fix.guardrail.patterns_override`: `false` to disable a default; Hash to add a custom (must include `regex`). Tripped → `REVIEW_WAITING reason=fix_guardrail pass=NN` and `reviews/fix-guardrail-NN.md` written.

## Phase 5 — browser test (`Hive::Stages::Review::BrowserTest`)

Only when Phase 2 produced zero findings (`pass=NN-1` was clean). Spawns the configured CE skill (`/compound-engineering:ce-test-browser` via `cfg.review.browser.agent`) which the agent invokes against the worktree. Returns one of `:passed`, `:warned`, `:skipped`, `:failed`. `:failed` is treated as `:warned` after `review.browser.max_attempts` (default 2) — the runner writes `browser-blocked-NN.md` and sets `REVIEW_COMPLETE browser=warned` rather than blocking the loop indefinitely.

`review.browser.enabled: false` skips the phase entirely; `:skipped` lands `browser=skipped` on the terminal marker.

## Stale-`REVIEW_WORKING` recovery (closes doc-review C-7 / ADV-12)

If the runner restarts on a `REVIEW_WORKING phase=X pass=N` marker with no live `.lock` holder, the prior run was interrupted. Recovery is per-phase, never mid-stream:

- **Interrupted at `phase=ci`** — re-run Phase 1 from scratch (idempotent).
- **Interrupted at `phase=reviewers`** — count `reviews/<*>-NN.md` for the current pass. If at least one exists, treat Phase 2 as complete-with-partial-results (missing reviewers get a stub `reviewer_failed` entry); proceed to Phase 3. If zero exist, re-run Phase 2.
- **Interrupted at `phase=triage`** — if `escalations-<pass>.md` exists, treat Phase 3 as complete; otherwise re-run (triage is idempotent — same reviewer files yield the same `[x]` marks under the deterministic stub).
- **Interrupted at `phase=fix`** — check `git log` for commits since the head of the current pass's reviewer files. Commits exist → treat Phase 4 as complete; loop with `pass++`. None → re-run Phase 4 (most fixes are file-level idempotent).
- **Interrupted at `phase=browser`** — re-run Phase 5 (idempotent).

The runner overwrites the stale marker as it enters the new phase. Resume entry-points are phase boundaries only.

## REVIEW_STALE recovery (max_passes / wall_clock)

1. Inspect the highest-NN per-reviewer files; either edit them down (consolidate/trim findings) or rename the highest NN to a lower NN (drops the derived pass count).
2. Remove the `<!-- REVIEW_STALE … -->` marker from `task.md`.
3. `hive run` again — the loop picks up at `max_review_pass(reviews/) + 1`.

No frontmatter edits required: pass count is filename-derived, not stored.

## Tests

- `test/integration/run_review_test.rb` — pre-flight short-circuits, missing-worktree handling, clean fast path, CI hard-block, wall-clock cap.
- `test/unit/stages/review/{ci_fix,triage,browser_test,fix_guardrail}_test.rb` — phase-level unit coverage.
- `test/unit/reviewers_test.rb`, `test/unit/reviewers/agent_test.rb` — adapter dispatch + agent-kind reviewer.
- `test/unit/metrics_test.rb`, `test/integration/metrics_command_test.rb` — `hive metrics rollback-rate` against trailered fixture commits.

## Backlinks

- [[stages/execute]] · [[stages/pr]]
- [[modules/markers]] · [[modules/agent]] · [[modules/config]]
- [[state-model]] · [[decisions]] · [[architecture]]

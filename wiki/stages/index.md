---
title: Stages Index
type: index
source: lib/hive/stages/
created: 2026-04-25
updated: 2026-06-03
tags: [stage, index]
---

**TLDR**: Nine wired pipeline stages, no gaps. PR creation happens before review in `5-open-pr`; `7-artifacts` is the artifact-collection handoff; `8-finalize` refreshes the PR and marks it ready.

| Stage | Runner | State file | Spawns agent? | Page |
|-------|--------|------------|----------------|------|
| 1-inbox | `Hive::Stages::Inbox` | `idea.md` | no | [[stages/inbox]] |
| 2-brainstorm | `Hive::Stages::Brainstorm` | `brainstorm.md` | yes | [[stages/brainstorm]] |
| 3-plan | `Hive::Stages::Plan` | `plan.md` | yes | [[stages/plan]] |
| 4-execute | `Hive::Stages::Execute` | `task.md` (+ `worktree.yml`) | yes (impl-only since U9) | [[stages/execute]] |
| 5-open-pr | `Hive::Stages::OpenPr` | `pr.md` | yes | [[stages/open-pr]] |
| 6-review | `Hive::Stages::Review` (orchestrator) + `Review::{CiFix,Triage,BrowserTest,FixGuardrail}` + `Reviewers::Agent` | `task.md` (+ `reviews/ce-review-*-NN.md`, `reviews/escalations-NN.md`, `reviews/ci-blocked.md`, `reviews/browser-test-NN.md`, `reviews/fix-guardrail-NN.md`) | yes (CI-fix + reviewers + triage + fix + browser) | [[stages/review]] |
| 7-artifacts | `Hive::Stages::Artifacts` | `artifact.md` | yes | [[stages/artifacts]] |
| 8-finalize | `Hive::Stages::Finalize` | `pr.md`, `summary.md` | yes | [[stages/finalize]] |
| 9-done | `Hive::Stages::Done` | `task.md` | no | [[stages/done]] |

All active stages share `Hive::Stages::Base.spawn_agent` for headless agent invocation (`AgentProfile`-resolved binary; default `claude -p`) and `Hive::Stages::Base.spawn_claude!` for Claude-backed launches that honor project-global `claude.mode`. `Hive::Stages::Base.render(template_name, bindings)` handles ERB prompt rendering. In tmux mode, marker-owned Claude launches wait through `Hive::ClaudeLauncher.wait_for_terminal_marker`; if the managed tmux session disappears before a terminal marker is written, the launcher stamps `ERROR reason=tmux_session_terminated` immediately instead of waiting for the stage timeout. 6-review uses per-spawn `status_mode` overrides so the orchestrator's `REVIEW_WORKING` marker survives sub-spawns; Claude reviewers use one shared tmux session per pass when `claude.mode: tmux`.

## 6-review phase order

1. **CI** (`Review::CiFix`, U7) — runs `review.ci.command` once on entry; on failure feeds log to fix agent up to `review.ci.max_attempts`. Hard-block → `REVIEW_CI_STALE` + `reviews/ci-blocked.md`.
2. **Reviewers** (`Reviewers::Agent`, U4) — dispatches each configured reviewer via `Hive::Reviewers.dispatch(spec, ctx)`; writes `reviews/ce-review-<name>-<NN>.md`. All reviewers fail → `REVIEW_ERROR`. `kind: "linter"` is rejected (use `review.ci.command`).
3. **Triage** (`Review::Triage`, U6) — `courageous` (default) or `safetyist` bias preset, with `review.triage.custom_prompt` override (path-escape-guarded). Concatenates `[x]` lines from per-reviewer files into accepted findings. SHA-256 protects `plan.md`/`worktree.yml`/`task.md`.
4. **Fix** — spawns fix agent with `accepted_findings` wrapped in per-spawn nonce. Agent's commits must carry trailers (`Hive-Fix-Pass`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase: fix`) — surfaced by `hive metrics rollback-rate` (U14).
4b. **Fix-guardrail** (`Review::FixGuardrail`, U13/ADR-020) — scans `git diff base..head` of fix-pass commits; matches against `Hive::SecretPatterns` and `Review::FixGuardrail::Patterns::DEFAULTS` (shell-pipe-to-interpreter, CI workflow edits, dotenv, lockfiles, mode 100755). Hit → `REVIEW_WAITING reason=fix_guardrail` + `reviews/fix-guardrail-NN.md`.
5. **Browser-test** (`Review::BrowserTest`, U8) — once per pass when `review.browser_test.enabled`. Spawns a browser-driver agent and parses a JSON result protocol; failure → `REVIEW_WAITING reason=browser_test`.

Loop terminates with one of: `REVIEW_COMPLETE` (clean) · `REVIEW_WAITING` (user input or fix-guardrail) · `REVIEW_STALE` (`max_passes` or `wall_clock` budget) · `REVIEW_CI_STALE` · `REVIEW_ERROR`.

`REVIEW_WAITING` resume: re-running `hive run` skips Phase 2/3 and re-enters Phase 4 with the user's manually-toggled `[x]` marks (so triage doesn't overwrite their decisions).

## Backlinks

- [[architecture]] · [[state-model]] · [[cli]] · [[commands/approve]] · [[commands/run]] · [[modules/markers]]

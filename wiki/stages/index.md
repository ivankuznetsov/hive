---
title: Stages Index
type: index
source: lib/hive/stages/
created: 2026-04-25
updated: 2026-10-14
tags: [stage, index]
---

**TLDR**: Nine wired coding pipeline stages, plus reusable descriptor-backed agent and council runners for custom workflows. PR creation happens before review in `5-open-pr`; `7-artifacts` is the artifact-collection handoff; `8-finalize` refreshes the PR and marks it ready.

| Stage | Runner | State file | Spawns agent? | Page |
|-------|--------|------------|----------------|------|
| 1-inbox | `Hive::Stages::Inbox` | `idea.md` | no | [[stages/inbox]] |
| 2-brainstorm | `Hive::Stages::Brainstorm` | `brainstorm.md` | yes | [[stages/brainstorm]] |
| 3-plan | `Hive::Stages::Plan` | `plan.md` | yes | [[stages/plan]] |
| 4-execute | `Hive::Stages::Execute` | `task.md` (+ `worktree.yml`) | yes (impl-only since U9) | [[stages/execute]] |
| 5-open-pr | `Hive::Stages::OpenPr` | `pr.md` | yes | [[stages/open-pr]] |
| 6-review | `Hive::Stages::Review` (orchestrator) + `Review::{CiFix,RemoteCi,Triage,BrowserTest,FixGuardrail}` + `Hive::Reviewers` adapters | `task.md` (+ `reviews/*-NN.md`, `reviews/escalations-NN.md`, `reviews/ci-blocked.md`, `reviews/browser-test-NN.md`, `reviews/fix-guardrail-NN.md`) | yes (local/hosted CI-fix + reviewers + triage + fix + browser) | [[stages/review]] |
| 7-artifacts | `Hive::Stages::Artifacts` | `artifact.md` | yes | [[stages/artifacts]] |
| 8-finalize | `Hive::Stages::Finalize` | `pr.md`, `summary.md` | yes | [[stages/finalize]] |
| 9-done | `Hive::Stages::Done` | `task.md` | no | [[stages/done]] |

All active stages share `Hive::Stages::Base.spawn_agent` for headless agent invocation (`AgentProfile`-resolved binary; default `claude -p`) and `Hive::Stages::Base.spawn_claude!` for Claude-backed launches, which always run headless `claude -p` through `Hive::ClaudeLauncher` (there is no Claude launch mode). Before spawning, coding/review stages call `Base.stage_permission_scope` to resolve the effective `permissions:` spec from config. Yolo/absent specs keep a Claude stage's default `--allowedTools` set (non-Claude providers get no built-in tool list), while non-yolo Claude scopes override the built-in allowlist and add `--allowedTools`/`--disallowedTools` plus any extra task-relative add-dirs. Every Claude launch through `spawn_agent` without a workflow `runtime_policy` also denies `AskUserQuestion`, because a detached `claude -p` stage has no one to answer a question menu. `Hive::Stages::Base.render(template_name, bindings)` handles ERB prompt rendering. `Hive::Stages::Base.spawn_claude_with_failure_marker!` turns a non-routing `Hive::AgentError` from a Claude launch into `ERROR reason=claude_launch_failed`; provider-limit output is classified as `limits_reached` by the headless agent path. Legacy tmux-era reasons (`tmux_session_terminated`, `interactive_menu_stranded`, `tmux_unavailable`) can still appear on task records written before the upgrade and render through the normal error path.

Every persisted `ERROR` / `REVIEW_ERROR` except the exact operator-owned
`terminal_outcome_blocked` and `terminal_outcome_invalid` reasons enters the
same marker-id-guarded, unbounded recovery lifecycle after the shared cooldown
when current ownership and work-area safety permit. `StaleAgentHealer`
schedules; `RecoveryCoordinator` persists the owning stage command and alone
clears/dispatches, including for `3-plan`. 6-review uses per-spawn `status_mode`
overrides so the orchestrator's `REVIEW_WORKING` marker survives sub-spawns;
Claude reviewers run as independent headless spawns like every other agent
reviewer.

`Hive::Stages::Agent` is a reusable descriptor-backed headless runner for
future `kind: :agent` stages outside the coding runner names. See
[[stages/agent]].

`Hive::Stages::Council` is a reusable descriptor-backed document review runner
for `kind: :council` custom workflow stages. See [[stages/council]].
Generic agent and council runners share `Base.marker_commit_action`, including
the markerless `nil` commit result that prevents empty audit commits.

## 6-review phase order

1. **CI** (`Review::CiFix` + `Review::RemoteCi`, U7) — runs optional `review.ci.command`, publishes with an exact PR-head lease, and settles the hosted check suite. Failure feeds bounded logs to the fix agent up to `review.ci.max_attempts`. The gates repeat when the reviewer-clean HEAD changed; a CI repair gets a fresh reviewer pass. Hard-block → `REVIEW_CI_STALE` + `reviews/ci-blocked.md`.
2. **Reviewers** (`Hive::Reviewers`, U4) — dispatches each configured reviewer via `Hive::Reviewers.dispatch(spec, ctx)`. `kind: "agent"` spawns a CE-skill reviewer; `kind: "codex_review"` runs native `codex review` and captures stdout into `reviews/<output_basename>-<NN>.md`. All reviewers fail → `REVIEW_ERROR`. `kind: "linter"` is rejected (use `review.ci.command`).
3. **Triage** (`Review::Triage`, U6) — `courageous` (default) or `safetyist` bias preset, with `review.triage.custom_prompt` override (path-escape-guarded). Concatenates `[x]` lines from per-reviewer files into accepted findings. SHA-256 protects `plan.md`/`worktree.yml`/`task.md`.
4. **Fix** — spawns fix agent with `accepted_findings` wrapped in per-spawn nonce. Agent's commits must carry trailers (`Hive-Fix-Pass`, `Hive-Triage-Bias`, `Hive-Reviewer-Sources`, `Hive-Fix-Phase: fix`) — surfaced by `hive metrics rollback-rate` (U14).
4b. **Fix-guardrail** (`Review::FixGuardrail`, U13/ADR-020) — scans `git diff base..head` of fix-pass commits; matches against `Hive::SecretPatterns` and `Review::FixGuardrail::Patterns::DEFAULTS` (shell-pipe-to-interpreter, CI workflow edits, dotenv, lockfiles, mode 100755). Hit → `REVIEW_WAITING reason=fix_guardrail` + `reviews/fix-guardrail-NN.md`.
5. **Browser-test** (`Review::BrowserTest`, U8) — once per pass when `review.browser_test.enabled`. Spawns a browser-driver agent and parses a JSON result protocol; persistent failure is recorded as `browser=warned` on `REVIEW_COMPLETE` rather than blocking the review loop indefinitely.

Loop terminates with one of: `REVIEW_COMPLETE` (clean) · `REVIEW_WAITING` (user input or fix-guardrail) · `REVIEW_STALE` (`max_passes` or `wall_clock` budget) · `REVIEW_CI_STALE` · `REVIEW_ERROR`.

`REVIEW_WAITING` resume: re-running `hive run` skips Phase 2/3 and re-enters Phase 4 with the user's manually-toggled `[x]` marks (so triage doesn't overwrite their decisions).

## Backlinks

- [[architecture]] · [[state-model]] · [[cli]] · [[commands/approve]] · [[commands/run]] · [[modules/markers]] · [[stages/agent]] · [[stages/council]]

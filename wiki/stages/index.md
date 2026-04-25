---
title: Stages Index
type: index
source: lib/hive/stages/
created: 2026-04-25
updated: 2026-04-26
tags: [stage, index]
---

**TLDR**: Seven wired pipeline stages — `5-review` is now in `Hive::Stages::DIRS`. Two stages are inert (1-inbox, 7-done); five spawn agents today. Each has exactly one state file and one runner module.

| Stage | Runner | State file | Spawns agent? | Page |
|-------|--------|------------|----------------|------|
| 1-inbox | `Hive::Stages::Inbox` | `idea.md` | no | [[stages/inbox]] |
| 2-brainstorm | `Hive::Stages::Brainstorm` | `brainstorm.md` | yes | [[stages/brainstorm]] |
| 3-plan | `Hive::Stages::Plan` | `plan.md` | yes | [[stages/plan]] |
| 4-execute | `Hive::Stages::Execute` | `task.md` (+ `worktree.yml`) | yes (impl only since U9) | [[stages/execute]] |
| 5-review | `Hive::Stages::Review` (orchestrator) + `Review::{CiFix,Triage,BrowserTest,FixGuardrail}` + `Hive::Reviewers::Agent` | `task.md` (+ `reviews/`, `reviews/escalations-NN.md`, `reviews/ci-blocked.md`, `reviews/fix-guardrail-NN.md`, `reviews/browser-NN.md`) | yes (CI-fix → reviewers → triage → fix → browser) | [[stages/review]] |
| 6-pr | `Hive::Stages::Pr` | `pr.md` | yes (unless idempotent) | [[stages/pr]] |
| 7-done | `Hive::Stages::Done` | `task.md` | no | [[stages/done]] |

All five active stages share `Hive::Stages::Base.spawn_agent` for agent invocation (`AgentProfile`-resolved binary; default `claude -p`) and `Hive::Stages::Base.render(template_name, bindings)` for ERB prompt rendering. The 5-review sub-spawns reuse the same `spawn_agent` pathway with per-spawn `status_mode` overrides (U4) so the orchestrator's `REVIEW_WORKING` marker survives every sub-spawn.

## 5-review pipeline (U9 shipped)

Phases inside a single `hive run` on a `5-review/<slug>/` task:

1. **Phase 1 — CI fix** (once on entry, skipped on `REVIEW_WAITING` resume) — `Review::CiFix`. Hard-blocks → `REVIEW_CI_STALE` + `reviews/ci-blocked.md`.
2. **Phase 2 — reviewers** — sequential `Review::Agent` spawns per `cfg["review"]["reviewers"]`. All-failed → `REVIEW_ERROR phase=reviewers reason=all_failed`. Empty list = OK (jump to Phase 5).
3. **Phase 3 — triage** — `Review::Triage` (`courageous` default / `safetyist`). SHA-256 protects `plan.md` / `worktree.yml` / `task.md`. Tampered → `REVIEW_ERROR phase=triage`.
4. **Branch:**
   - any `[x]` accepted → **Phase 4 (fix)** → loop back to Phase 2 with `pass++`.
   - escalations-only → `REVIEW_WAITING` (terminal until user toggles `[x]` and re-runs).
   - all clean → Phase 5.
5. **Phase 4 — fix** — `templates/fix_prompt.md.erb` agent. SHA-256 around `plan.md` / `worktree.yml` / `task.md`. Then `Review::FixGuardrail` (U13 stub today, returns `:clean`) on the diff between pre- and post-fix `HEAD`; `:tripped` writes `reviews/fix-guardrail-NN.md` and sets `REVIEW_WAITING reason=fix_guardrail`.
6. **Phase 5 — browser test** — `Review::BrowserTest`. `:passed` / `:warned` / `:skipped` → `REVIEW_COMPLETE pass=N browser=<status>`.

`review.max_wall_clock_sec` (default 5400) is checked at every phase boundary; tripping it lands `REVIEW_STALE reason=wall_clock`. `review.max_passes` (default 4) caps the pass loop; tripping it lands `REVIEW_STALE`.

**Resume rules:**
- `REVIEW_WAITING` resume → skip Phase 1/2/3, jump straight to Phase 4 with the user's manually-toggled `[x]` marks (re-running triage would overwrite them).
- `REVIEW_CI_STALE` / `REVIEW_STALE` / `REVIEW_ERROR` short-circuit at the top of `run!` with a stderr hint.
- Pass derivation is filesystem-native: `next_pass = max NN suffix of reviews/*-NN.md + 1` (escalations / ci-blocked / browser / fix-guardrail filenames excluded). Recovery = delete the highest-NN files to drop the pass back.

## Backlinks

- [[architecture]] · [[state-model]] · [[cli]] · [[commands/approve]] · [[modules/markers]]

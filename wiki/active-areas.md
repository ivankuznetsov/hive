---
title: Active Areas
type: active-areas
source: git log + working tree
created: 2026-04-25
updated: 2026-04-26
tags: [roadmap, status]
---

**TLDR**: Phase 1 MVP shipped Apr-25. The 5-review stage and its sub-pipeline (CI-fix, sequential reviewers, triage, fix, fix-guardrail, browser-test) shipped on `feat/5-review-stage` (branch in flight 2026-04-26). 295 unit/integration tests green; `hive metrics rollback-rate` operational.

## Status

Working tree clean as of 2026-04-25. Three commits on `main`:
1. `c2098f0` — initial Phase 1 MVP (folder-as-agent pipeline).
2. `873b1ae` — post-MVP review hardening (P0 worktree-hijack + 9 P1 fixes).
3. `1b05ccb` — agent-failure propagation, live-claude smoke, secondary review fixes.

## What exists

| Area | Files | Status |
|------|-------|--------|
| CLI surface | `bin/hive`, `lib/hive/cli.rb`, `lib/hive/commands/{init,new,run,status}.rb` | Implemented + integration-tested |
| Stage runners | `lib/hive/stages/{base,inbox,brainstorm,plan,execute,pr,done}.rb` | Implemented + integration-tested |
| Core modules | `lib/hive/{task,markers,lock,worktree,git_ops,agent,config}.rb` | Implemented + unit-tested |
| Templates | `templates/*.erb` (8 files) | Drafted |
| Tests | `test/unit/*.rb`, `test/integration/*.rb` (94 tests / 299 assertions) | All green |
| Live smoke | `test/smoke/live_claude_smoke_test.rb` (`rake smoke`) | Opt-in; verified 2 / 11 cases |
| CI | `.github/workflows/ci.yml`, `.github/dependabot.yml`, `config/brakeman.ignore` | Wired |
| Repo hygiene | `CHANGELOG.md`, `SECURITY.md`, `.github/ISSUE_TEMPLATE/`, `.github/PULL_REQUEST_TEMPLATE.md` | Authored |
| Docs | `README.md`, `wiki/` knowledge base | Authored |

## Phase 1 deferred work

- ~~Additional reviewers in `4-execute` (Codex local, pr-review-toolkit, rubocop-as-reviewer).~~ Shipped under [[stages/review]] (multi-reviewer set runs in 5-review, not 4-execute; rubocop-style linters belong in `review.ci.command` per ADR-014).
- Parallel reviewers (Phase 2 of 5-review). Currently sequential (ADR-015); add behind a config flag if wall-clock cost becomes painful.
- Trailer-validation log for fix commits that miss `Hive-Fix-*` trailers (planned in U14, dropped — agents that obey the prompt land trailers; the rollback-rate metric just gets noisier when one slips through).
- Second pilot project and cross-project `hive status`.
- Atomic rollback via snapshot tags on `hive/state` per stage transition (Phase 3).
- `hive reinit <new-path>` for migrating registered project paths.
- `--stage` / `--slug` flags on `hive new` if ergonomics warrants it.

## Phase 2/3 work (also deferred)

- Dispatcher daemon at `~/Dev/hive/daemon.rb` with polling + fswatch.
- Telegram bot bidirectional adapter.
- Observability probes track (`<project>/.hive-state/reports/`).
- QMD export of `7-done/` task artefacts to per-project learning collections.
- `gh api` PR-comment ingestion into `reviews/pr-comments-NN.md`.

## What's NOT implemented yet (per plan)

- `--force` flag on `hive run` for `EXECUTE_STALE` recovery — current MVP requires manual marker removal + frontmatter edit.
- macOS fallback for PID-reuse detection (currently Linux `/proc/<pid>/stat` only).
- Pre-commit hook integration on `hive/state` commits — flagged as a known caveat in the plan's Risks table.

## Backlinks

- [[gaps]]
- [[architecture]]
- [[decisions]]

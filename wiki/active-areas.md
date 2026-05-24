---
title: Active Areas
type: active-areas
source: git log + working tree
created: 2026-04-25
updated: 2026-05-14
tags: [roadmap, status]
---

**TLDR**: Phase 1 MVP shipped Apr-25. The 6-review loop, PR-first draft/finalize flow, daemon dispatcher, rollback-rate metric, auto-rebase pre-step, and Telegram bot mobile surface are now implemented. Current deferred work is mostly depth/scale: parallel reviewers, observability exports, richer PR-comment ingestion, and daemon/bot operational polish.

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
| Daemon (ADR-024) | `lib/hive/daemon/*`, `lib/hive/commands/daemon.rb`, `wiki/commands/daemon.md`, `wiki/modules/daemon.md` | Auto-advancing dispatcher: polls `hive status --json`, fires workflow verbs on tasks ready to advance, auto-archives 8-finalize after PR merge via `gh pr view`. Per-project enrolled at `hive init` (default Y). |
| Telegram bot (ADR-026) | `lib/hive/bot/*`, `lib/hive/commands/bot.rb`, `wiki/commands/bot.md`, `wiki/modules/bot.md` | Mobile human-input surface: long-polls Telegram, notifies on waiting/recovery gates, writes brainstorm answers under lock, and dispatches existing `hive` commands from inline buttons. |
| Global Claude launch mode (ADR-030) | `lib/hive/claude_launcher.rb`, `lib/hive/stages/base.rb` (`spawn_claude!`), `lib/hive/commands/init/prompts.rb`, `lib/hive/commands/doctor.rb`, `docs/adrs/030-global-claude-launch-mode.md`, `docs/notes/claude-tmux-launch-mode.md` | Top-level `claude.mode` (default `tmux`) routes every Claude-backed stage (brainstorm/plan/execute/open-pr/artifacts/finalize + 6-review Claude reviewers) through one shared tmux launcher per pass. `tmux >= 3.0` is a hard runtime dep when mode is `tmux`. `hive init` prompts; `hive doctor` reports. `brainstorm.runtime` deprecated to brainstorm-only fallback. |

## Phase 1 deferred work

- ~~Additional reviewers in `4-execute` (Codex local, pr-review-toolkit, rubocop-as-reviewer).~~ Shipped under [[stages/review]] (multi-reviewer set runs in 6-review, not 4-execute; rubocop-style linters belong in `review.ci.command` per ADR-014).
- Parallel reviewers (Phase 2 of 6-review). Currently sequential (ADR-015); add behind a config flag if wall-clock cost becomes painful.
- Trailer-validation log for fix commits that miss `Hive-Fix-*` trailers (planned in U14, dropped — agents that obey the prompt land trailers; the rollback-rate metric just gets noisier when one slips through).
- Second pilot project and cross-project `hive status`.
- Atomic rollback via snapshot tags on `hive/state` per stage transition (Phase 3).
- `hive reinit <new-path>` for migrating registered project paths.
- `--stage` / `--slug` flags on `hive new` if ergonomics warrants it.

## Phase 2/3 work (also deferred)

- ~~Dispatcher daemon at `~/Dev/hive/daemon.rb` with polling + fswatch.~~ Shipped (polling-only) under ADR-024. fswatch deferred behind `daemon.fswatch.enabled: true`.
- ~~Telegram bot bidirectional adapter.~~ Shipped under ADR-026 as `hive bot`.
- Observability probes track (`<project>/.hive-state/reports/`).
- QMD export of `9-done/` task artefacts to per-project learning collections.
- `gh api` PR-comment ingestion into `reviews/pr-comments-NN.md`.
- `hive daemon doctor` — first-time-setup health check (verifies `gh auth status`, registered projects, daemon-enabled flags).
- TUI live integration of daemon state (read-only "Daemon" pane).

## What's NOT implemented yet (per plan)

- `--force` flag on `hive run` for `EXECUTE_STALE` recovery — current MVP requires manual marker removal + frontmatter edit.
- macOS fallback for PID-reuse detection (currently Linux `/proc/<pid>/stat` only).
- Pre-commit hook integration on `hive/state` commits — flagged as a known caveat in the plan's Risks table.

## Backlinks

- [[gaps]]
- [[architecture]]
- [[decisions]]
- [[commands/bot]] · [[modules/bot]]

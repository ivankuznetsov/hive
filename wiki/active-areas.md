---
title: Active Areas
type: active-areas
source: git log + working tree
created: 2026-04-25
updated: 2026-06-12
tags: [roadmap, status]
---

**TLDR**: Phase 1 MVP shipped Apr-25 and the active surface is now wider than the original loop: PR-first review, `7-artifacts`, daemon auto-advance/archive, TUI dashboard, Telegram bot, managed llm-wiki bootstrap, release/install verification, eval harness, token usage accounting, and project-global Claude tmux/headless routing are all implemented. Current deferred work is mostly depth/scale: parallel reviewers, observability exports, richer PR-comment ingestion, daemon/bot operational polish, and cross-platform smoke depth.

## Status

Daemon autostart hardening landed on `main` via #189 (2026-05-26): autostart is now install-time/global infrastructure. A Linux host without systemd-user writes the unit and reports the `unsupported` success outcome (exit 0) instead of a spurious failure; `install.sh` captures the real install exit code and carries the verified `hive`/`hv` wrapper through daemon install + `hive init`; `Hive::InvokedBinary` replaces the dead `which` delegators. See log entries 2026-05-26 (21:22Z / 22:55Z / 23:30Z) and ADR-024.

Recent release/dependency history inspected on 2026-06-12:

| Commit | Area | Notes |
|--------|------|-------|
| `64b11b41` | Release | Prepares v0.3.0: sets `Hive::VERSION` and the lockfile path gem to `0.3.0`, points public Linux installer snippets at `v0.3.0`, and adds release notes for hivebox alpha, the first GHCR hivebox image release, session-limit healing, dispatch-request/drop schema v2, golden-path E2E, and Windows installer harness coverage. |
| `2e307a19` | Dependency lockfile | Relocks the root bundle after the earlier `rack-test` manifest removal; root `Gemfile.lock` no longer lists `rack-test` as a resolved gem or top-level dependency. |
| `416c8a9c` | Wiki refresh | Documents the patrol native `codex review` reviewer default and associated init/config/review page drift. |
| `c7d8aa4f` | Release | Tags v0.2.4 from `main`; the release prep commit sets `Hive::VERSION` and the lockfile path gem to `0.2.4`, points public Linux installer snippets at `v0.2.4`, and adds release notes for `claude.model` / `claude.effort` pins. |
| `d9f9887d` | Claude launch config | Adds project-global `claude.model` / `claude.effort` pins for both headless and tmux Hive-launched Claude sessions, with `hive init` prompts and schema/test coverage. |
| `6b9f14bb` | Wiki refresh | Documents v0.2.3 release prep plus the Claude/tmux orphan-sweep contract across release, agent, brainstorm, testing, and gaps pages. |
| `1c3baa8a` | Release | Tags v0.2.3 from `main`; the release prep commit sets `Hive::VERSION` and the lockfile path gem to `0.2.3` and points public Linux installer snippets at `v0.2.3`. |
| `024b29b0` | Claude/tmux cleanup | Replaces blanket orphan-sweep `pkill -f` with `pgrep` plus per-PID `TERM`, skipping matched `tmux` server commands and logging killed/skipped rows. |
| `903eb7dc` | Provider limits | Hardens Claude plan-inclusion banner handling so ordinary plan/usage copy no longer triggers `limits_reached`. |
| `b2e568ba` | Patrol review cost | Adds the native `codex review` reviewer path for patrol PRs while keeping the fuller review path for human PRs. |

## What exists

| Area | Files | Status |
|------|-------|--------|
| CLI surface | `bin/hive`, `lib/hive/cli.rb`, `lib/hive/commands/*.rb` | Implemented. Command pages exist for the active Thor surface, including daemon, bot, TUI, markers, migrate, findings, metrics, update, uninstall, and stage-action helpers. |
| Stage runners | `lib/hive/stages/{inbox,brainstorm,plan,execute,open_pr,review,artifacts,finalize,done}.rb` | Nine-stage pipeline implemented and documented in [[stages/index]]. `7-artifacts` is agent-backed and sits between review and finalize. |
| Core modules | `lib/hive/{task,markers,lock,worktree,git_ops,agent,agent_profile,config,task_action,...}.rb` | Implemented + unit-tested by domain. Agent spawning is AgentProfile-driven; Claude launches can be tmux or headless via `Hive::ClaudeLauncher`. |
| Daemon (ADR-024) | `lib/hive/daemon/*`, `lib/hive/commands/daemon.rb`, `wiki/commands/daemon.md`, `wiki/modules/daemon.md` | Auto-advancing dispatcher: polls `hive status --json`, fires workflow verbs on tasks ready to advance, auto-archives 8-finalize after PR merge via `gh pr view`, heals stale AGENT_WORKING markers, and now counts `live_task_lock` rows toward capacity. |
| TUI | `lib/hive/tui/*`, `wiki/commands/tui.md`, `wiki/token-usage.md` | Bubbletea-ruby MVU dashboard with grid/detail flows, red-status detail, manual steering, token footer, and token matrix. |
| Telegram bot (ADR-026) | `lib/hive/bot/*`, `lib/hive/commands/bot.rb`, `wiki/commands/bot.md`, `wiki/modules/bot.md` | Mobile human-input surface: long-polls Telegram, notifies on waiting/recovery gates, writes brainstorm answers under lock, and dispatches existing `hive` commands from inline buttons. `hive bot install` adds an opt-in reboot-survivable per-user service (systemd-user/launchd) that runs `hive bot start --foreground` with no inline token; torn down by `hive uninstall`. |
| Shared service installer | `lib/hive/commands/service_installer/{base,outcome}.rb`, `lib/hive/commands/{daemon,bot}/service_installer.rb`, `schemas/hive-{bot,daemon}-install.v1.json`, `docs/solutions/…cross-platform-service-installer-base…` | `ServiceInstaller::Base` extracted from the daemon installer (daemon behavior byte-identical) and subclassed by daemon + bot, returning a `ServiceInstaller::Outcome` value object. Content-comparison drift detection (`--force` to overwrite), `unsupported` outcome on hosts with no service manager, exit codes 0/64/70, and a read-only `service_state` probe surfaced as `service_installed`/`service_enabled`/`unit_path` in both `bot`/`daemon status --json`. |
| Testing and eval | `test/unit/`, `test/integration/`, `test/e2e/`, `test/eval/`, `Rakefile`, `bin/hive-eval` | Default `bundle exec rake test`; strict `bundle exec rake coverage`; opt-in e2e and Telegram bot eval layers. |
| Release/install | `install.sh`, `install.md`, `packaging/`, `.github/workflows/install-smoke.yml`, `.github/workflows/release.yml` | v0.3.0 release prep is gem-based across Homebrew, AUR, and `install.sh`, and the release notes add hivebox alpha plus the first GHCR hivebox image release surface. Update/uninstall, release artifact verification, daemon service install JSON envelopes, hivebox Docker install/smoke flow, and remaining tag-trust/macOS x86_64/live-provider follow-ups are documented in [[operating]], [[commands/web]], [[testing]], and [[gaps]]. |
| Docs/wiki | `README.md`, `docs/notes/`, `wiki/`, `.llm-wiki/` | Managed llm-wiki context is installed for Codex/Claude/Pi; refresh automation is Codex-owned by `.llm-wiki/config.json`. |

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
- Pre-commit hook integration on `hive/state` commits — flagged as a known caveat in the plan's Risks table.

## Backlinks

- [[gaps]]
- [[architecture]]
- [[decisions]]
- [[commands/bot]] · [[modules/bot]]

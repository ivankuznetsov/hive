---
title: Active Areas
type: active-areas
source: git log + working tree
created: 2026-04-25
updated: 2026-07-18
tags: [roadmap, status]
---

**TLDR**: Phase 1 MVP shipped Apr-25 and the active surface is now wider than the original loop: PR-first review, `7-artifacts`, daemon auto-advance/archive, descriptor-backed custom workflows with resource controls, Claude/Codex/Pi/Grok agent profiles, `hive refactor-patrol`, TUI dashboard, Telegram bot, managed llm-wiki bootstrap, release/install verification, eval harness, token usage accounting, and project-global Claude tmux/headless routing are all implemented. Current deferred work is mostly depth/scale: parallel reviewers, observability exports, richer PR-comment ingestion, daemon/bot operational polish, and live-provider smoke depth.

## Status

Daemon autostart hardening landed on `main` via #189 (2026-05-26): autostart is now install-time/global infrastructure. A Linux host without systemd-user writes the unit and reports the `unsupported` success outcome (exit 0) instead of a spurious failure; `install.sh` captures the real install exit code and carries the verified `hive`/`hv` wrapper through daemon install + `hive init`; `Hive::InvokedBinary` owns both stable-wrapper resolution and the shared PATH-only executable lookup used by doctor, update, and service installation. See log entries 2026-05-26 (21:22Z / 22:55Z / 23:30Z) and ADR-024.

Recent release/dependency/history inspected on 2026-07-18:

| Commit | Area | Notes |
|--------|------|-------|
| `#695` / `#713` | Grok agent backend | Adds the built-in Grok profile, streaming response assembly, config/diagnosis/web/TUI surfaces, compact report-only reviewer, and direct `GROK_AUTH_PATH` precedence shared by preflight and login status. |
| `#700` | Workflow resource controls | Adds descriptor-level `timeout_sec` / `budget_usd` for agent and council stages, including process-group timeout enforcement and explicit unsupported-budget warnings. |
| `#656` | Refactor patrol | Adds `hive refactor-patrol` as a bounded architecture-cleanup discovery command feeding the existing patrol workflow. |
| `54fd3455` | Release / hivebox image smoke | Replaces the broken hosted macOS/Colima post-publish arm64 smoke with native `ubuntu-24.04-arm` Docker and records green validation against the live `ghcr.io/ivankuznetsov/hivebox:0.3.1` arm64 image. |
| `9efbca2a` | Release / custom workflows | Prepares v0.3.1, syncs both root and web path-gem lockfile versions, points public Linux installer snippets at `v0.3.1`, and updates README/release notes around custom workflows as the headline feature. |
| `9ca14ae0` | Dependency / web tests | Bumps the root RuboCop constraint and lockfile to 1.88, and adds retry/child-diff handling for rare generated task slug collisions in the Rails web test helper. |
| `4d1a55f9` / `52d23099` | Dependency / root bundle | Bump the root lockfile's `concurrent-ruby` to 1.3.7 for CVE-2026-54904/5/6 and Brakeman to 8.0.5; the web bundle remains independently locked. |
| `59941c79` | Screenote artifacts | Replaces the old API-token uploader with `hive connect/disconnect screenote`, OAuth 2.1 auth-code + PKCE, MCP project listing, credential storage, and Claude-only MCP injection during artifacts. |
| `3bf09727` | Review suppression | Adds base-SHA-bound no-fix suppression so a finding triaged as `RESOLVED/NO-FIX` does not keep re-entering later review passes. |
| `c0175459` | Worktree stacking | Hardens dependency override branches so empty placeholders are re-pointed onto the prerequisite branch instead of collapsing stacked work onto the default branch. |
| `ee49830f` | Workflow setup | Makes workflow choice a first-class setup step in CLI and hivebox project creation, with project-authored workflows advertised in `--workflow` help. |
| `0d0cac16` | Native Codex reviewer | Drops the verbose `codex review` exec/thinking/codex session transcript from published findings while keeping the High/Medium/Nit block and final Codex reply, reducing triage prompt bloat. |
| `70e6ff14` | Hivebox agent login | Completes operator-ward device-flow UI behavior for Codex and `gh`: poll until the CLI exits, hide the paste-back form, and render done/error state. Claude remains paste-back. |
| `b370e7c3` | Hivebox assets | Replaces the placeholder icon with terracotta honeycomb SVG/PNG assets and adds `/favicon.ico` so root favicon requests stop 404ing. |
| `c75f4039` | Hivebox agent login | Sanitizes captured agent-login URLs by replacing terminal-control runs with spaces before re-extracting the first URL, preventing adjacent URLs from being spliced into one href. |
| `c5cd70a9` / `b08703a3` / `5c645734` | Hivebox agent login | Moves Codex to `login --device-auth`, strips ANSI from surfaced URLs, and exercises binary PTY output through the controller/view path so login-status pages do not 500 on raw CLI bytes. |
| `7b17bfd6` | Finalize | Fast-forwards stale rebase-duplicate worktrees so finalize does not loop on `unpushed_commits`. |
| `f25896a2` | Tmux prompt submit | Replaces fixed paste-to-Enter sleep with pane-tail settle polling so large Claude/tmux prompts submit after the paste fully renders. |
| `7f088c48` | Review triage defaults | Aligns `Review::Triage`'s partial-config fallback budget/timeout with `Config::DEFAULTS` (`review_triage` = 75 / 1800), closing a test/internal-caller footgun. Loaded project config already received these values through the deep merge. |
| `118ed2fd` | Provider limits / finalize | Narrows AgentLimit's broad limit match to usage-qualified walls so UI feature prose like scroll/window limits does not trip `limits_reached`, and lets finalize short-circuit already-merged PRs to `COMPLETE merged=true` before stale local-branch checks. |
| `fce1a3a3` | Daily digest (superseded engine) | Historical internal `Hive::Digest` implementation; current `hive digest` retains daemon scheduling and registered-project selection but delegates the engine and JSON contract to PRDigest. |
| `7b0a02fd` | Babysitter dry-run | Blocks `GIT_EXEC_PATH` in the git dry-run stub so repo-configured remote helpers cannot execute through an allowlisted read command. |
| `2b5b51b9` | Babysitter dry-run | Pins wrapper-launcher handoff so command-local `HIVE_BABYSITTER_REAL_GIT` / `HIVE_BABYSITTER_REAL_GH` overrides cannot replace the parent-resolved real binaries. |
| `aa160a2c` | Install smoke CI | Hardens the `verify-release.sh (end-to-end behavior)` job so `jq` provisioning first uses runner-provided `jq`, then falls back to apt, and retries after disabling transiently broken `packages.microsoft.com` apt sources. |
| `c9d08bfe` | Review error reasons | Classifies residual triage/fix phase-agent failures as `merge_conflict`, `network_timeout`, `tool_permission_denied`, `agent_crashed`, or `unknown` while keeping provider/rate limits on the existing `limits_reached` cooldown path. |
| `b6bba5d6` | Review limit healing | Routes triage/fix phase provider-limit failures through `REVIEW_ERROR reason=limits_reached retry_after=...`, matching the existing reviewers-phase cooldown path instead of terminal generic phase-failure markers. |
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
| Release/install | `install.sh`, `install.md`, `packaging/`, `.github/workflows/install-smoke.yml`, `.github/workflows/release.yml` | v0.5.3 release prep synchronizes both path-gem locks and public installer pins for the bounded Architecture Patrol merged-PR intake fix. Update/uninstall, release artifact verification, install-smoke `jq` provisioning, daemon service install JSON envelopes, hivebox Docker install/smoke flow, and remaining signed-tag/macOS x86_64/live-provider follow-ups are documented in [[operating]], [[commands/web]], [[testing]], and [[gaps]]. |
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

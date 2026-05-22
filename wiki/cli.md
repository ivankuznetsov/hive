---
title: CLI Surface
type: api
source: bin/hive, lib/hive/cli.rb
created: 2026-04-25
updated: 2026-05-22
tags: [cli, api]
---

**TLDR**: Hive exposes a Thor-based CLI. The human workflow is `hive status` followed by stage verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`) that move-or-run tasks by slug. `run`, `approve`, `findings`, `markers`, and `metrics` are the lower-level agent/script surface. `hive tui` is the human-only dashboard over `hive status`; `hive daemon` auto-advances safe rows; `hive bot` runs the Telegram mobile surface for human-input gates. `status`, `run`, `approve`, `findings`, `markers`, `metrics`, daemon lifecycle/enrollment, and bot lifecycle support `--json` where documented. Process exit codes are stable per `Hive::ExitCodes` so wrappers can branch deterministically.

## Entry point

`bin/hive` is a thin runner that loads `lib/hive` and calls `Hive::CLI.start(ARGV)`, catching `Hive::Error` to render `hive: <message>` to stderr with the error's `exit_code` (default `ExitCodes::GENERIC = 1`).

## Command table

| Command | Synopsis | Routes to | Page |
|---------|----------|-----------|------|
| `hive init [PROJECT_PATH]` | Bootstrap `.hive-state` orphan branch + worktree plus managed llm-wiki context in a git project | `Hive::Commands::Init` | [[commands/init]] |
| `hive new PROJECT TEXT...` | Create a task in `1-inbox/` of a registered project | `Hive::Commands::New` | [[commands/new]] |
| `hive status [--diagnose SLUG [--write [--force]] [--project NAME] [--stage STAGE]]` | Action-grouped task list across registered projects. With `--diagnose <slug>`, prints the bounded diagnostic for one task (schema `hive-status-diagnose`). Add `--write` to spawn the configured execute `AgentProfile` and atomically write `<task>/diagnostics/red-status.md` (no lock, no marker mutation; `--force` bypasses the `marker_signature` idempotency short-circuit; green rows are rejected). | `Hive::Commands::Status` (delegates write path to `Hive::DiagnosisAgent`) | [[commands/status]] |
| `hive tui` | Live, keystroke-driven Charm bubbletea + lipgloss dashboard over `hive status` (human-only; rejects `--json`) | `Hive::Tui` | [[commands/tui]] |
| `hive daemon SUBCOMMAND` | Auto-advance pipeline dispatcher. Subcommands: `start` / `stop` / `status` / `reload` / `tail` for the daemon process; `install [--force]` to (re)write the platform-native unit file (preserves operator hand-edits without `--force`; rotates the prior file to `<path>.bak-<ts>` and restarts the daemon with `--force`); `enable PROJECT \| --all` and `disable` for per-project enrollment (atomic write to `<project>/.hive-state/config.yml`). Polls `hive status --json` and fires workflow verbs on tasks ready to advance; auto-archives 8-finalize after PR merge. The dispatcher also runs `Hive::Daemon::StaleAgentHealer` on every tick, which rewrites `AGENT_WORKING` markers whose backing agent isn't alive to `ERROR reason=agent_died` / `reason=agent_orphaned` (grace = `daemon.agent_marker_grace_sec`, default 300s). New projects opt in at `hive init` (default Y); existing ones via `hive daemon enable`. See [[operating]] for the install + systemd/launchd setup guide. | `Hive::Commands::Daemon` | [[commands/daemon]] |
| `hive bot SUBCOMMAND` | Telegram bot lifecycle. Subcommands: `start` / `stop` / `status` / `reload` / `tail`. Long-polls Telegram, authenticates by `bot.chat_id_allowlist`, notifies on waiting/recovery gates, and dispatches existing `hive` commands from inline buttons. | `Hive::Commands::Bot` | [[commands/bot]] |
| `hive brainstorm TARGET [--from STAGE]` | Start or re-run brainstorm by slug/path | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive plan TARGET [--from STAGE]` | Promote completed brainstorm to plan, or re-run plan | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive develop TARGET [--from STAGE]` | Promote completed plan to execute, or re-run execute | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive open-pr TARGET [--from STAGE]` | Promote completed execute to draft PR creation, or re-run open-pr | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive review TARGET [--from STAGE]` | Promote opened draft PR to review, or re-run review | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive artifacts TARGET [--from STAGE]` | Promote completed review to artifact collection, or re-run artifacts | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive finalize TARGET [--from STAGE]` | Promote completed artifacts to PR finalization, or re-run finalize | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive archive TARGET [--from STAGE]` | Promote finalized PR to done, or re-run done | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive run TARGET [--no-rebase]` | Lower-level dispatcher for a slug or task folder. `--no-rebase` skips the auto-rebase pre-step for one invocation (one-off override of `cfg.rebase.enabled`). | `Hive::Commands::Run` → stage runner | [[commands/run]] |
| `hive rebase-status TARGET` | Read-only inspector: reports whether the next `hive run` would attempt an auto-rebase, how many commits behind `origin/<default>` the worktree is, and which guard (if any) would short-circuit. Never mutates; never calls `git fetch`. | `Hive::Commands::RebaseStatus` | [[commands/rebase-status]] |
| `hive approve TARGET [--to STAGE] [--from STAGE]` | Move a task between stages + record a hive/state commit (agent-callable equivalent of shell `mv`; `--from` asserts current stage for retry idempotency) | `Hive::Commands::Approve` | [[commands/approve]] |
| `hive findings TARGET [--pass N] [--stage STAGE]` | List GFM-checkbox findings in `reviews/ce-review-NN.md` (latest by default) | `Hive::Commands::Findings` | [[commands/findings]] |
| `hive accept-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Tick `[x]` on review findings; selectors are unioned | `Hive::Commands::FindingToggle` (accept) | [[commands/findings]] |
| `hive reject-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Untick `[x]` on review findings | `Hive::Commands::FindingToggle` (reject) | [[commands/findings]] |
| `hive markers clear FOLDER --name <NAME> [--project NAME] [--json]` | Remove a recovery marker (`REVIEW_STALE`, `REVIEW_CI_STALE`, `REVIEW_ERROR`, `EXECUTE_STALE`, `ERROR`) from a task's state file (atomic write + hive_commit). Terminal-success markers (`REVIEW_COMPLETE` / `EXECUTE_COMPLETE` / `COMPLETE`) are deliberately rejected — use `hive approve` instead. | `Hive::Commands::Markers` | [[commands/markers]] |
| `hive metrics SUBCOMMAND [--days N] [--project NAME] [--json]` | Compute project-wide metrics. Currently one subcommand: `rollback-rate` walks `git log --all` and reports the fraction of fix-commits (those carrying `Hive-Fix-Pass` trailer) that were later reverted, broken down by `Hive-Triage-Bias` and `Hive-Fix-Phase`. | `Hive::Commands::Metrics` → `Hive::Metrics` | — |
| `hive update` | Re-run the install channel that originally placed the binary (xdg/homebrew/aur). Reads channel from `~/.local/state/hive/install-channel` (or `Hive::InstallChannel.detect`) and re-invokes the matching installer; refuses to act when the channel is unknown. See `lib/hive/commands/update.rb`. | `Hive::Commands::Update` | — |
| `hive uninstall [--purge]` | Remove user-scoped hive runtime: stop daemon/bot, remove launchd/systemd units, drop xdg-installed binary, prune `~/.local/state/hive`. `--purge` also removes the global registry at `$HIVE_HOME` (default `~/Dev/hive/config.yml`). Never touches per-project `.hive-state/` working trees. See `lib/hive/commands/uninstall.rb`. | `Hive::Commands::Uninstall` | — |
| `hive migrate [PROJECT_PATH]` | One-shot rename of in-flight task folders from the pre-open-pr stage layout to the current 9-stage layout. | `Hive::CLI#migrate` | — |
| `hive doctor [--json]` | Walk `brainstorm` + `plan` stage configs and every `review.reviewers[]` entry, asking each agent profile to verify its configured skill resolves to an installed slash-command / SKILL.md on disk. When `brainstorm.runtime == "tmux_interactive"` also adds a `kind: "dependency"` row checking tmux availability + minimum version. Also runs non-fatally at the tail of `hive init`. Exits 0 / 65 / 78. | `Hive::Commands::Doctor` | [[commands/doctor]] |
| `hive forget NAME [--json]` | Drop one named entry from the global registry (`~/Dev/hive/config.yml`). Inverse of `hive init`. The project's `.hive-state` directory on disk is not touched. Unknown name → exit 64. | `Hive::Commands::Forget` | [[commands/forget]] |
| `hive prune [--dry-run] [--json]` | Drop every registry entry whose `path` is no longer a directory on disk OR whose row shape is invalid (hand-edit accident). `--dry-run` returns the would-be-removed list without writing. | `Hive::Commands::Prune` | [[commands/prune]] |
| `hive version` / `hive --version` | Print `Hive::VERSION` and exit 0. Used by e2e environment snapshots and binary smoke tests. | `Hive::CLI#version` | — |

`Hive::CLI` (`lib/hive/cli.rb`) is the Thor class. Notable mappings:

- `new_task` is mapped to the user-visible `new` (Thor reserves `new`).
- `run_task` is mapped to `run`.
- Stage verbs use `--from` for source-stage disambiguation because the verb already implies the target stage.
- `init` accepts `--force` (skip clean-tree check).
- `--json` is a `class_option` honoured by `status`, `run`, `rebase-status`, `approve`, `findings`, `accept-finding`, `reject-finding`, the workflow verbs (`brainstorm`, `plan`, `develop`, `open-pr`, `review`, `artifacts`, `finalize`, `archive`), `markers clear`, `metrics`, `forget`, `prune`, the `daemon` subcommands (`status`, `stop`, `reload`, `enable`, `disable`), and the `bot` lifecycle subcommands (`status`, `stop`, `reload`). Daemon lifecycle JSON is published as `hive-daemon-status.v1` / `-stop.v1` / `-reload.v1` / `-enroll.v1`; bot lifecycle JSON is published as `hive-bot-status.v1` / `-stop.v1` / `-reload.v1`. Each command with full envelope support emits a typed JSON document on success and a structured error envelope on failure. Workflow verbs emit a single `hive-stage-action` envelope (inner Approve and Run are passed `quiet: true` to avoid double-emission). `rebase-status` emits a sibling read-only `hive-rebase-status` envelope — not validated against `hive-run.v1`.
- `bin/hive` rewrites `<cmd> --help` / `<cmd> -h` into `help <cmd>` before Thor dispatch, so the convention agents try first works (without the rewrite, Thor would consume `--help` as the next positional argument).
- `bin/hive` handles top-level `--version` / `-v` before Thor dispatch so wrappers can smoke-test the binary without parsing help output.

## Exit-code contract (`Hive::ExitCodes`)

| Code | Constant | Meaning | Raised by |
|------|----------|---------|-----------|
| 0 | `SUCCESS` | command completed | — |
| 1 | `GENERIC` | unclassified `Hive::Error` | base `Hive::Error` |
| 2 | `ALREADY_INITIALIZED` | idempotent reject of `hive init` on existing project | `Hive::AlreadyInitialized` |
| 3 | `TASK_IN_ERROR` | a stage agent recorded `:error` (runner itself succeeded) | `Hive::TaskInErrorState` |
| 4 | `WRONG_STAGE` | `hive run` invoked on an inert stage (e.g. `1-inbox`) | `Hive::WrongStage` |
| 64 | `USAGE` | EX_USAGE — bad slug, malformed task path | `Hive::InvalidTaskPath` |
| 70 | `SOFTWARE` | EX_SOFTWARE — git, worktree, agent, or stage-runner failure | `GitError`, `WorktreeError`, `AgentError`, `StageError` |
| 75 | `TEMPFAIL` | EX_TEMPFAIL — retryable lock contention | `Hive::ConcurrentRunError` |
| 78 | `CONFIG` | EX_CONFIG — bad project / global config | `Hive::ConfigError` |

Codes are stable; bumping a code requires updating `test/unit/exit_codes_test.rb`. See [CONTRIBUTING.md](../CONTRIBUTING.md) "CLI contract for agent callers".

## Authentication / preconditions

The CLI itself has no auth. Preconditions checked at runtime by individual stage runners:

- Per-spawn `AgentProfile#check_version!` + `preflight!` (Claude: parses `claude --version` against `Hive::MIN_CLAUDE_VERSION = "2.1.118"`; Codex/Pi: profile-specific). Raises `AgentError` on mismatch. Default profile is `:claude`; `Stages::Base.spawn_agent(profile:)` selects an alternate via `Hive::AgentProfiles.lookup(...)`.
- `Hive::Gh.ensure_authenticated!` (called from both `Stages::OpenPr` and `Stages::Finalize`) runs `gh auth status` and exits 1 with stderr if unauthenticated. `Stages::OpenPr` invokes `Hive::Gh.push_branch!` before spawning the open-pr agent; `Stages::Finalize` invokes `Hive::Gh.push_branch` (non-`!`) so a persistent push failure surfaces as `ERROR reason=unpushed_commits` instead of an uncaught exit.
- `Init#validate_git_repo!` rejects non-git dirs and rejects targets that are themselves worktrees (must run on the main checkout).
- `Init#validate_clean_tree!` aborts on dirty working tree unless `--force`.

## Error conventions

`Hive::Error` is the root exception. Subclasses define stage-shaped failure modes; each overrides `exit_code` so `bin/hive`'s rescue path produces the contract code automatically.

| Class | Raised by |
|-------|-----------|
| `Hive::InvalidTaskPath` | `Task#initialize` for paths not matching the regex |
| `Hive::ConcurrentRunError` | `Lock.acquire_task_lock` when another live PID owns `.lock` |
| `Hive::GitError` | `GitOps#run_git!` on non-zero git exit |
| `Hive::WorktreeError` | `Worktree#create!`/`remove!` and pointer validation |
| `Hive::AgentError` | `Agent.check_version!` |
| `Hive::ConfigError` | `Config.load`/`registered_projects` on shape mismatch |
| `Hive::StageError` | `Commands::Run#pick_runner` for unknown stage names |
| `Hive::TaskInErrorState` | `Commands::Run#report` when the stage marker is `:error` |
| `Hive::WrongStage` | `Stages::Inbox#run!` (running an agent on an inert stage) |
| `Hive::AlreadyInitialized` | `Commands::Init#call` when `hive/state` branch already exists |

A few stage runners still call `warn`/`exit N` directly for non-bug user errors that don't yet have a typed class — most notably `Init#validate_git_repo!` / `validate_clean_tree!` (exit 1), `Execute#run!` for `plan.md missing` (exit 1), and the `OpenPr` / `Finalize` network/auth abort paths. Migrating these to typed exceptions is tracked as Phase 2 follow-up work.

**Error envelopes.** Every `--json`-supporting command (`status`, `run`, `approve`, `findings`, `accept-finding`, `reject-finding`, `markers clear`, `metrics rollback-rate`, and the workflow verbs `brainstorm` / `plan` / `develop` / `open-pr` / `review` / `artifacts` / `finalize` / `archive`) emits a `Hive::Schemas::ErrorEnvelope` document on stdout when an error is raised. Detect failure by `payload.ok == false`. The envelope carries `schema`, `schema_version`, `ok=false`, `error_class`, `error_kind` (a closed enum per command — see `Hive::Schemas::RunErrorKind` / `StatusErrorKind` / etc.), `exit_code` (matches the raised `Hive::Error`'s `exit_code` per `Hive::ExitCodes`), and `message`. Per-error structured extras (`candidates` for `AmbiguousSlug`, `id` for `UnknownFinding`, `path` for `DestinationCollision`, `stage` for `FinalStageReached`) appear automatically. `hive run --json` additionally preserves the existing dual-signal contract on `:error` / `:review_error` markers — the SuccessPayload is emitted to stdout BEFORE the `TaskInErrorState` raise, so the rescue's ErrorPayload is suppressed (one document, exit 3). Errors that fire before Thor parses argv (gem-load failures, shebang errors) cannot emit JSON — those remain stderr-text + exit-code only.

## Backlinks

- [[architecture]]
- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/rebase-status]] · [[commands/status]] · [[commands/approve]] · [[commands/findings]] · [[commands/stage_action]] · [[commands/bot]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/review]] · [[stages/artifacts]] · [[stages/finalize]] · [[stages/done]]

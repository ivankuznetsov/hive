---
title: CLI Surface Architecture
type: api
source: bin/hive, bin/hive-e2e, bin/hv, lib/hive/cli.rb, lib/hive/runtime_identity.rb, lib/hive/cli_argv_policy.rb, lib/hive/remote/command_policy.rb, lib/hive/remote/dispatcher.rb, lib/hive/connection_contexts.rb
created: 2026-04-25
updated: 2026-11-27
tags: [cli, api, skills, agents, operational, provisioning, brainstorm, plan-review, proposals]
---

> **Public CLI authority:** [docs/cli.md](../docs/cli.md) is the single authoritative public CLI reference for every visible `bin/hive` command, subcommand, alias, option, JSON/JSON-Lines/text framing contract, remote-context rule, side effect, and exit code. This page documents the internal CLI entry-point architecture and maps commands to their internal Wiki architecture pages.

## Entry point and wrapper architecture

`bin/hive` loads `lib/hive`, runs client context preflight and argv normalization, and dispatches to `Hive::CLI.start(ARGV)` (Thor), catching `Hive::Error` subclasses to report `hive: <message>` on stderr and exit with `error.exit_code` (`Hive::ExitCodes`).

- **Client context boundary (`Hive::Remote::CommandPolicy`, `Hive::ConnectionContexts`, `Hive::Remote::Dispatcher`):** Resolves the active connection context before runtime activation, process registration, scheduler reconciliation, or project discovery. `ConnectionContexts` persists versioned client metadata and separate owner-only credentials under `Hive::Paths.config_home/connections` using locked atomic writes; unknown newer schemas fail closed without falling back to `local`. Internal native `hive`/`hv` children spawned by task naming, daemon, bot, one-shot, and TUI execution carry explicit local context isolation so a saved remote selection cannot redirect admitted local work. Remote transport keeps TLS verification enabled, refuses redirects, bounds connect/read timeouts and response sizes, and never retries POST automatically. See [[commands/context]], [[commands/operation]], and [[remote-access]].
- **Shared argv policy (`Hive::CliArgvPolicy`):** Pure wrapper normalization shared by `bin/hive` and `bin/hive-e2e` for UTF-8 argument validation, Thor-exact boolean flag grammar, leading-option placement, command-local help rewriting, literal `--` boundaries, and `new` option lifting before Thor dispatch.
- **Pre-dispatch usage contracts (`Hive::CliUsageContracts`) and `Hive::Schemas::EnvelopeEmitter`:** Command boundaries register pre-dispatch Thor usage error contracts so invalid invocations still emit the owning command's structured envelope when requested. After dispatch, commands using `Hive::Schemas::ErrorEnvelope` share `EnvelopeEmitter` for single-document guards, closed-pipe handling, and per-command serialization failure policies (`:suppress`, `:raise`, `:warn`).
- **Apache Hive fallback launcher (`bin/hv`):** Bash launcher that probes only `HIVE_BIN_OVERRIDE`, `${XDG_BIN_HOME:-$HOME/.local/bin}/hive`, `${HOMEBREW_PREFIX:-/opt/homebrew}/bin/hive`, and `/usr/local/bin/hive`, isolating each version probe in its own process group with a watchdog timeout (exit `124` on hang, `127` if no owned binary is found) so it never falls through to `/usr/bin/hive` or `/opt/hive/bin/hive`. See [[operating]].
- **Runtime SQLite startup contention:** Ordinary commands preserve a 15-second SQLite busy timeout per operation; exhaustion aborts before command work. Default running status shares a one-second budget and degrades to partial status while preserving daemon/runtime liveness data. See [[commands/status]].

## Authentication and runtime preconditions

The CLI itself carries no user auth; stage runners and setup boundaries enforce runtime preconditions:

- Per-spawn `AgentRuntime.prepare!` delegates provider version and local configuration checks to `agent-cli-runtime`, applies Hive policy, launches CLI subscription/session state only, and scrubs ambient provider API credentials. `Stages::Base.spawn_agent(profile:)` selects profiles via `Hive::AgentProfiles.lookup(...)`.
- `Hive::Gh.ensure_authenticated!` verifies `gh auth status` in `Stages::OpenPr` and `Stages::Finalize`; `Stages::OpenPr` calls `Hive::Gh.push_branch!` before spawning, while `Stages::Finalize` calls non-bang `push_branch` so push failures record a task error marker rather than crashing uncaught.
- `Init#validate_git_repo!` rejects non-git directories and linked worktrees; `Init#validate_clean_tree!` guards dirty trees.

## Exception hierarchy (`Hive::Error`)

`Hive::Error` (`lib/hive/errors.rb`) is the root typed exception; subclasses map failure categories to `Hive::ExitCodes`:

| Class | Raised by |
|---|---|
| `Hive::UsageError` | Canonical generic argument/usage failures |
| `Hive::InvalidTaskPath` | Task/path resolution failures and preserved `invalid_task_path` contracts |
| `Hive::ConcurrentRunError` | `Lock.acquire_task_lock` when another live PID holds `.lock` |
| `Hive::GitError` | `GitOps#run_git!` on non-zero git exit |
| `Hive::WorktreeError` | `Worktree#create!`/`remove!` and pointer validation |
| `Hive::AgentError` | `Agent.check_version!` and `AgentRuntime.prepare!` |
| `Hive::ConfigError` | `Config.load` and registry shape validation |
| `Hive::StageError` | `Commands::Run#pick_runner` for unknown stage names |
| `Hive::TaskInErrorState` | `Commands::Run#report` when the stage marker is `:error` |
| `Hive::WrongStage` | `Stages::Inbox#run!` and invalid stage transitions |
| `Hive::AlreadyInitialized` | `Commands::Init#call` when `hive/state` already exists |

## Command index

Architecture destinations for internal controller, storage, and subsystem documentation (for public CLI behavior, use [docs/cli.md](../docs/cli.md)):

| Command | Owner |
| --- | --- |
| `hive accept-finding` | [[commands/findings]] |
| `hive act` | [[commands/status]] |
| `hive answer` | [[commands/answer]] |
| `hive answer-digest` | [[commands/answer-digest]] |
| `hive approve` | [[commands/approve]] |
| `hive archive` | [[commands/stage_action]] |
| `hive artifacts` | [[commands/stage_action]] |
| `hive babysit` | [[commands/babysit]] |
| `hive bench` | [[commands/bench-submit]] |
| `hive bot` | [[commands/bot]] |
| `hive brainstorm` | [[commands/stage_action]] |
| `hive connect` | [[commands/screenote]] |
| `hive context` | [[commands/context]] |
| `hive daemon` | [[commands/daemon]] |
| `hive decide` | [[commands/workflow]] |
| `hive develop` | [[commands/stage_action]] |
| `hive digest` | [[commands/digest]] |
| `hive disconnect` | [[commands/screenote]] |
| `hive doctor` | [[commands/doctor]] |
| `hive drop` | [[commands/drop]] |
| `hive evidence` | [[commands/evidence]] |
| `hive finalize` | [[commands/stage_action]] |
| `hive findings` | [[commands/findings]] |
| `hive forget` | [[commands/forget]] |
| `hive generate-name` | [[commands/generate-name]] |
| `hive help` | [[commands/help]] |
| `hive init` | [[commands/init]] |
| `hive markers` | [[commands/markers]] |
| `hive mcp` | [[commands/mcp]] |
| `hive metrics` | [[commands/metrics]] |
| `hive module` | [[commands/module]] |
| `hive new` | [[commands/new]] |
| `hive open-pr` | [[commands/stage_action]] |
| `hive operation` | [[commands/operation]] |
| `hive pairing` | [[commands/pairing]] |
| `hive patrol` | [[commands/patrol]] |
| `hive plan` | [[commands/stage_action]] |
| `hive plan-review` | [[modules/plan_review]] |
| `hive plan-review-run` | [[modules/plan_review]] |
| `hive proposal` | [[commands/proposal]] |
| `hive prune` | [[commands/prune]] |
| `hive publication-reconcile` | [[commands/publication-reconcile]] |
| `hive rebase-status` | [[commands/rebase-status]] |
| `hive receipt` | [[commands/receipt]] |
| `hive refactor-patrol` | [[commands/refactor-patrol]] |
| `hive reject-finding` | [[commands/findings]] |
| `hive review` | [[commands/stage_action]] |
| `hive review-grant` | [[commands/review-grant]] |
| `hive run` | [[commands/run]] |
| `hive runtime` | [[commands/runtime]] |
| `hive setup` | [[commands/setup]] |
| `hive setup-agents` | [[commands/setup-agents]] |
| `hive stack` | [[commands/stack]] |
| `hive status` | [[commands/status]] |
| `hive task` | [[commands/task]] |
| `hive token` | [[commands/token]] |
| `hive tree` | [[commands/tree]] |
| `hive tui` | [[commands/tui]] |
| `hive uninstall` | [[commands/uninstall]] |
| `hive update` | [[commands/update]] |
| `hive version` | [[commands/version]] |
| `hive watch` | [[commands/watch]] |
| `hive web` | [[commands/web]] |
| `hive wiki` | [[commands/wiki]] |
| `hive workflow` | [[commands/workflow]] |
| `hive worktree` | [[modules/worktree]] |

## Backlinks

- [[architecture]] · [[commands]] · [[modules/gh]]
- [[commands/migrate]] (historical state conversion — removed command)
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/review]] · [[stages/artifacts]] · [[stages/finalize]] · [[stages/done]]

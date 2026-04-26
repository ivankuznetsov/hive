---
title: CLI Surface
type: api
source: bin/hive, lib/hive/cli.rb
created: 2026-04-25
updated: 2026-04-26
tags: [cli, api]
---

**TLDR**: Hive exposes a Thor-based CLI. The human workflow is `hive status` followed by stage verbs (`brainstorm`, `plan`, `develop`, `pr`, `archive`) that move-or-run tasks by slug. `run`, `approve`, and findings commands remain the lower-level agent/script surface. There is no daemon, no HTTP server, no sockets — the CLI is the entire control surface.

## Entry point

`bin/hive` is a thin runner that loads `lib/hive` and calls `Hive::CLI.start(ARGV)`, catching `Hive::Error` to render `hive: <message>` to stderr with the error's `exit_code` (default `ExitCodes::GENERIC = 1`).

## Command table

| Command | Synopsis | Routes to | Page |
|---------|----------|-----------|------|
| `hive init [PROJECT_PATH]` | Bootstrap `.hive-state` orphan branch + worktree in a git project | `Hive::Commands::Init` | [[commands/init]] |
| `hive new PROJECT TEXT...` | Create a task in `1-inbox/` of a registered project | `Hive::Commands::New` | [[commands/new]] |
| `hive status` | Action-grouped task list across registered projects | `Hive::Commands::Status` | [[commands/status]] |
| `hive brainstorm TARGET [--from STAGE]` | Start or re-run brainstorm by slug/path | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive plan TARGET [--from STAGE]` | Promote completed brainstorm to plan, or re-run plan | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive develop TARGET [--from STAGE]` | Promote completed plan to execute, or re-run execute | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive pr TARGET [--from STAGE]` | Promote completed execute to PR, or re-run PR | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive archive TARGET [--from STAGE]` | Promote completed PR to done, or re-run done | `Hive::Commands::StageAction` → approve/run | [[commands/stage_action]] |
| `hive run TARGET` | Lower-level dispatcher for a slug or task folder | `Hive::Commands::Run` → stage runner | [[commands/run]] |
| `hive approve TARGET [--to STAGE] [--from STAGE]` | Move a task between stages + record a hive/state commit (agent-callable equivalent of shell `mv`; `--from` asserts current stage for retry idempotency) | `Hive::Commands::Approve` | [[commands/approve]] |
| `hive findings TARGET [--pass N] [--stage STAGE]` | List GFM-checkbox findings in `reviews/ce-review-NN.md` (latest by default) | `Hive::Commands::Findings` | [[commands/findings]] |
| `hive accept-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Tick `[x]` on review findings; selectors are unioned | `Hive::Commands::FindingToggle` (accept) | [[commands/findings]] |
| `hive reject-finding TARGET [ID...] [--severity S] [--all] [--stage STAGE]` | Untick `[x]` on review findings | `Hive::Commands::FindingToggle` (reject) | [[commands/findings]] |

`Hive::CLI` (`lib/hive/cli.rb`) is the Thor class. Notable mappings:

- `new_task` is mapped to the user-visible `new` (Thor reserves `new`).
- `run_task` is mapped to `run`.
- Stage verbs use `--from` for source-stage disambiguation because the verb already implies the target stage.
- `init` accepts `--force` (skip clean-tree check).
- `--json` is a `class_option` honoured by `status`, `run`, `approve`, `findings`, `accept-finding`, `reject-finding`, and the five workflow verbs (`brainstorm`, `plan`, `develop`, `pr`, `archive`). Each emits a typed JSON document on success AND a structured error envelope on every failure path. Workflow verbs emit a single `hive-stage-action` envelope (inner Approve and Run are passed `quiet: true` to avoid double-emission).
- `bin/hive` rewrites `<cmd> --help` / `<cmd> -h` into `help <cmd>` before Thor dispatch, so the convention agents try first works (without the rewrite, Thor would consume `--help` as the next positional argument).

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

- `Hive::Agent.check_version!` parses `claude --version` and compares against `Hive::MIN_CLAUDE_VERSION = "2.1.118"`. Raises `AgentError` if below.
- `Stages::Pr#ensure_gh_authenticated!` runs `gh auth status` and exits 1 with stderr if unauthenticated.
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

A few stage runners still call `warn`/`exit N` directly for non-bug user errors that don't yet have a typed class — most notably `Init#validate_git_repo!` / `validate_clean_tree!` (exit 1), `Execute#run!` for `plan.md missing` (exit 1), and the `Pr` stage's network/auth abort paths. Migrating these to typed exceptions is tracked as Phase 2 follow-up work.

## Backlinks

- [[architecture]]
- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/status]] · [[commands/approve]] · [[commands/findings]] · [[commands/stage_action]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/pr]] · [[stages/done]]

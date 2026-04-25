---
title: CLI Surface
type: api
source: bin/hive, lib/hive/cli.rb
created: 2026-04-25
updated: 2026-04-25
tags: [cli, api]
---

**TLDR**: Hive exposes a Thor-based CLI with four commands: `init`, `new`, `run`, `status`. There is no daemon, no HTTP server, no sockets — the CLI is the entire control surface.

## Entry point

`bin/hive` is a thin runner that loads `lib/hive` and calls `Hive::CLI.start(ARGV)`, catching `Hive::Error` to render `hive: <message>` to stderr with the error's `exit_code` (default 1).

## Command table

| Command | Synopsis | Routes to | Page |
|---------|----------|-----------|------|
| `hive init [PROJECT_PATH]` | Bootstrap `.hive-state` orphan branch + worktree in a git project | `Hive::Commands::Init` | [[commands/init]] |
| `hive new PROJECT TEXT...` | Create a task in `1-inbox/` of a registered project | `Hive::Commands::New` | [[commands/new]] |
| `hive run FOLDER` | Run the stage agent for the task at `FOLDER` | `Hive::Commands::Run` → stage runner | [[commands/run]] |
| `hive status` | Tabular status across registered projects | `Hive::Commands::Status` | [[commands/status]] |

`Hive::CLI` (`lib/hive/cli.rb`) is the Thor class. Notable mappings:

- `new_task` is mapped to the user-visible `new` (Thor reserves `new`).
- `run_task` is mapped to `run`.
- `init` accepts `--force` (skip clean-tree check); other commands take no flags in MVP.

## Authentication / preconditions

The CLI itself has no auth. Preconditions checked at runtime by individual stage runners:

- `Hive::Agent.check_version!` parses `claude --version` and compares against `Hive::MIN_CLAUDE_VERSION = "2.1.118"` (`lib/hive.rb:3`). Raises `AgentError` if below.
- `Stages::Pr#ensure_gh_authenticated!` runs `gh auth status` and exits 1 with stderr if unauthenticated.
- `Init#validate_git_repo!` rejects non-git dirs and rejects targets that are themselves worktrees (must run on the main checkout).
- `Init#validate_clean_tree!` aborts on dirty working tree unless `--force`.

## Error conventions

`Hive::Error` (`lib/hive.rb:6`) is the root exception. Subclasses define stage-shaped failure modes:

| Class | Raised by |
|-------|-----------|
| `Hive::InvalidTaskPath` | `Task#initialize` for paths not matching the regex |
| `Hive::ConcurrentRunError` | `Lock.acquire_task_lock` when another live PID owns `.lock` |
| `Hive::GitError` | `GitOps#run_git!` on non-zero git exit |
| `Hive::WorktreeError` | `Worktree#create!`/`remove!` and pointer validation |
| `Hive::AgentError` | `Agent.check_version!` |
| `Hive::ConfigError` | `Config.load`/`registered_projects` on shape mismatch |
| `Hive::StageError` | `Commands::Run#pick_runner` for unknown stage names |

Stage runners use `warn`/`exit N` directly for user-facing errors that aren't bugs (e.g., `plan.md missing` → exit 1; `already initialized` → exit 2). See per-command pages.

## Backlinks

- [[architecture]]
- [[commands/init]] · [[commands/new]] · [[commands/run]] · [[commands/status]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/pr]] · [[stages/done]]

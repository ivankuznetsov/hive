---
title: Hive::Task
type: module
source: lib/hive/task.rb
created: 2026-04-25
updated: 2026-04-25
tags: [model, task, parsing]
---

**TLDR**: Pure parser/value-object that turns a task folder path into a structured `(project_root, hive_state_path, stage_index, stage_name, slug)` tuple plus derived paths (`state_file`, `worktree_path`, `lock_file`, `log_dir`, `commit_lock_file`, `reviews_dir`, `worktree_yml_path`).

## Constants

- `STAGE_NAMES = %w[inbox brainstorm plan execute pr done]`
- `STATE_FILES` — maps stage name → state file basename (`idea.md`, `brainstorm.md`, `plan.md`, `task.md`, `pr.md`, `task.md`).
- `PATH_RE = %r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/(?<stage_idx>\d+)-(?<stage_name>\w+)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])/?\z}` — the only validator for task paths.

## Constructor (`#initialize(folder)`)

1. `File.expand_path(folder)`.
2. Match `PATH_RE`; on failure, raise `Hive::InvalidTaskPath` with the offending path.
3. Validate `stage_name ∈ STAGE_NAMES`; on failure, raise `InvalidTaskPath` with `"unknown stage name: <name>"`.
4. Strip a trailing `/`, then capture into `@folder`, `@project_root`, `@state_dir_basename`, `@hive_state_path`, `@stage_index`, `@stage_name`, `@slug`.

`@hive_state_path` is the *project-rooted* hive-state path: `<project_root>/<state_dir_basename>` — always `<project_root>/.hive-state` in MVP.

## Derived accessors

| Method | Returns |
|--------|---------|
| `#project_name` | `File.basename(@project_root)` |
| `#state_file` | `File.join(folder, STATE_FILES[stage_name])` |
| `#reviews_dir` | `File.join(folder, "reviews")` |
| `#worktree_yml_path` | `File.join(folder, "worktree.yml")` |
| `#lock_file` | `File.join(folder, ".lock")` |
| `#log_dir` | `File.join(@hive_state_path, "logs", @slug)` |
| `#commit_lock_file` | `File.join(@hive_state_path, ".commit-lock")` |

## Worktree path resolution (`#worktree_path`)

Returns `nil` for stage indexes < 4 (no worktree before execute).

For 4–6:
1. If `worktree.yml` exists in the task folder, return `data["path"]` from it (the canonical pointer).
2. Otherwise fall back to `derive_worktree_path`: `<cfg["worktree_root"] || ~/Dev/<project_name>.worktrees>/<slug>`. This is the path that *would* be assigned, useful before `worktree.yml` is written.

## Why a class, not a module

`Task` carries identity (`@folder`, `@slug`, `@stage_name`) — it's a value object. All other path-like helpers are derived. `Markers`, `Lock`, `Config` etc. are stateless modules.

## Tests

- `test/unit/task_test.rb` — path parsing, invalid stage rejection, derived-path correctness, slug edge cases.

## Backlinks

- [[modules/markers]] · [[modules/lock]] · [[modules/worktree]]
- [[commands/run]] · [[commands/status]]
- [[state-model]]

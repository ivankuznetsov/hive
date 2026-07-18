---
title: Hive::Task
type: module
source: lib/hive/task.rb, lib/hive/task_meta.rb, lib/hive/task_counter.rb
created: 2026-04-25
updated: 2026-07-16
tags: [model, task, parsing, task-id, dependencies, workflows]
---

**TLDR**: Value object and sidecar helpers for task identity. `Hive::Task` turns a task folder path into a structured `(project_root, hive_state_path, stage_index, stage_name, slug, workflow)` tuple plus derived paths; `Hive::TaskMeta` reads `<task>/meta.yml` identity, dependency, and workflow-selector metadata; `Hive::TaskCounter` allocates global numeric ids for newly captured tasks.

## Constants

- `STAGE_NAMES = %w[inbox brainstorm plan execute open-pr review artifacts finalize done]` — 9 stages post-artifacts insertion, derived from `Hive::Workflows::Registry.default`. `open-pr` is hyphenated; the dash must be allowed by `PATH_RE`.
- `STATE_FILES` — maps stage name → state file basename (`idea.md`, `brainstorm.md`, `plan.md`, `task.md`, `pr.md`, `task.md`, `artifact.md`, `pr.md`, `task.md`), derived from the same ordered workflow descriptor.
- `PATH_RE = %r{\A(?<root>.+)/(?<state_dir>\.hive-state)/stages/(?<stage_idx>\d+)-(?<stage_name>[a-z][a-z0-9-]*)/(?<slug>[a-z][a-z0-9-]{0,62}[a-z0-9])/?\z}` — the only validator for task paths. The `[a-z][a-z0-9-]*` class for `stage_name` (no `\w+`) is what permits the dash in `5-open-pr`.

## Constructor (`#initialize(folder)`)

1. `File.expand_path(folder)`.
2. Match `PATH_RE`; on failure, raise `Hive::InvalidTaskPath` with the offending path.
3. Strip a trailing `/`, then capture into `@folder`, `@project_root`, `@state_dir_basename`, `@hive_state_path`, `@stage_index`, `@stage_name`, `@slug`.
4. Resolve `@workflow` from `<task>/meta.yml workflow:`, then project config `default_workflow`, then built-in `coding`. Missing/malformed `meta.yml` returns nil selector; recoverable broken project config falls back to `coding` with a warning. Unsupported project root keys are not recoverable: their `UnsupportedProjectConfigError` propagates as exit 78 before task-only commands can mutate state. Unknown workflow ids are re-raised as `InvalidTaskPath` so one bad task is skipped like a bad stage directory.
5. Validate the parsed stage name and numeric prefix against the selected descriptor. A descriptor without the stage, or a directory like `3-brainstorm` when the descriptor says `2-brainstorm`, raises `InvalidTaskPath`.

`@hive_state_path` is the *project-rooted* hive-state path: `<project_root>/<state_dir_basename>` — always `<project_root>/.hive-state` in MVP.

## Derived accessors

| Method | Returns |
|--------|---------|
| `#project_name` | `File.basename(@project_root)` |
| `#workflow` | Selected `Hive::Workflow` descriptor |
| `#stage_names` | Stage names from `#workflow`, not necessarily `Task::STAGE_NAMES` |
| `#state_file` | `File.join(folder, workflow.state_file_for(stage_name))` |
| `#reviews_dir` | `File.join(folder, "reviews")` |
| `#worktree_yml_path` | `File.join(folder, "worktree.yml")` |
| `#meta_yml_path` | `Hive::TaskMeta.path(folder)` |
| `#id` | Numeric id from `meta.yml`, or nil when absent/malformed/unallocated |
| `#display_name` | `display_name` from `meta.yml`, or nil |
| `#depends_on` | Single same-project id/slug or explicit `project:slug` prerequisite from `meta.yml`, or nil |
| `#display_label` | `display_name || slug` |
| `#lock_file` | `File.join(folder, ".lock")` |
| `#log_dir` | `File.join(@hive_state_path, "logs", @slug)` |
| `#commit_lock_file` | `File.join(@hive_state_path, ".commit-lock")` |

## Worktree path resolution (`#worktree_path`)

Returns `nil` for stage indexes < 4 (no worktree before execute).

For stages 4 and later:
1. If `worktree.yml` exists in the task folder, return `data["path"]` from it (the canonical pointer).
2. Otherwise fall back to `derive_worktree_path`: `<cfg["worktree_root"] || ~/Dev/<project_name>.worktrees>/<slug>`. This is the path that *would* be assigned, useful before `worktree.yml` is written.

## Why a class, not a module

`Task` carries identity (`@folder`, `@slug`, `@stage_name`) — it's a value object. All other path-like helpers are derived. `Markers`, `Lock`, `Config` etc. are stateless modules.

## Task metadata helpers

`Hive::TaskMeta` (`lib/hive/task_meta.rb`) owns the optional `<task>/meta.yml` sidecar:

- `read(task_folder)` returns `{id:, slug:, display_name:, depends_on:, workflow:}` and is total over missing, malformed, or non-Hash YAML.
- `read_for_admission(task_folder)` returns a result-bearing strict read. It distinguishes an absent legacy sidecar from unreadable YAML, a non-mapping document, and an invalid dependency reference; admission code must use this path rather than interpreting tolerant-read nil as “no dependency.”
- `write(task_folder, id:, slug:, display_name:, depends_on: nil, workflow: nil)` normalizes empty strings to nil, normalizes ids with `Integer(...)`, writes optional `depends_on` / `workflow` only when present, and writes through `.<meta>.tmp.<pid>.<hex>` plus `File.rename`.
- `update_display_name(task_folder, name)` preserves the existing id, slug, `depends_on`, and `workflow`, defaulting slug to `File.basename(task_folder)` only when the sidecar is absent. It refuses corrupt input.
- `update_id(task_folder, id)` preserves slug, display name, `depends_on`, and `workflow`, and likewise refuses corrupt input; daemon backfill cannot sanitize dependency evidence by replacing a damaged mapping.

`Hive::TaskCounter` (`lib/hive/task_counter.rb`) owns `<state_home>/task-counter.yml`:

- `next!` locks `<state_home>/.task-counter.lock`, returns the current id, then writes `next_id: id + 1`.
- `next_or_nil` performs the same allocation but returns nil only when the counter lock times out, for capture paths that can be repaired by the daemon's id backfiller.
- `peek` returns the current `next_id`, defaulting to `1` on missing or corrupt YAML.
- `seed_at_least!(next_id)` advances the counter floor without moving it backwards.
- Lock timeout raises `Hive::ConcurrentRunError` with `lock_path` set to the counter lock.

## Tests

- `test/unit/task_test.rb` — path parsing, descriptor-driven stage/index validation, workflow selection fallback, derived-path correctness, slug edge cases, and `meta.yml` readers.
- `test/unit/task_meta_test.rb` — tolerant and strict sidecar reads, dependency validation, workflow selector preservation, corrupt-input mutation refusal, display-name updates, and id backfill.
- `test/unit/task_counter_test.rb` — first id, sequential ids, fail-soft allocation, corrupt counter fallback, seeding, forked concurrency, and lock timeout.

## Backlinks

- [[modules/markers]] · [[modules/lock]] · [[modules/worktree]]
- [[modules/task_dependencies]] · [[modules/workflows]]
- [[commands/run]] · [[commands/status]]
- [[state-model]]

---
title: hive run
type: command
source: lib/hive/commands/run.rb
created: 2026-04-25
updated: 2026-04-26
tags: [command, dispatcher, stages, json]
---

**TLDR**: `hive run TARGET` is the lower-level dispatcher for a slug or task folder. It resolves `TARGET` into a `Hive::Task`, takes the per-task lock, picks the matching stage runner, executes it, commits any `.hive-state` changes via the per-project commit lock, and reports the resulting marker plus a workflow-oriented `next:` hint. Most humans should start with `hive status` and use `hive brainstorm|plan|develop|pr|archive <slug>`.

## Usage

```
hive run <slug> [--project NAME] [--stage STAGE] [--json]
hive run <project>/.hive-state/stages/<N>-<stage>/<slug> [--json]
```

`TARGET` is resolved by `Hive::TaskResolver`. Bare slugs search registered projects; `--project` scopes cross-project collisions; `--stage` scopes same-slug stage collisions. Folder paths remain exact and authoritative.

## Steps performed (`Commands::Run#call`)

1. Resolve `TARGET` via `Hive::TaskResolver` and load merged config via `Hive::Config.load(task.project_root)`.
2. Acquire the per-task lock via `Hive::Lock.with_task_lock` with payload `{slug:, stage:}`. Concurrent run → `ConcurrentRunError` (exit 75, `TEMPFAIL`, stderr `hive: another hive run is active`).
3. `pick_runner(task)` returns one of `Hive::Stages::{Inbox,Brainstorm,Plan,Execute,Review,Pr,Done}.method(:run!)`. Unknown stage → `StageError`.
4. Call the runner: `runner.call(task, cfg)` → `{commit:, status:}`.
5. `commit_after`: if `result[:commit]`, take the per-project commit lock and run `GitOps#hive_commit(stage_name: "<N>-<stage>", slug:, action: result[:commit])`.
6. `report`: print the current marker, the state file path, and a stage-aware next step.

## next: hints (by marker)

| Marker | `report` output |
|--------|-----------------|
| `:waiting` / `:execute_waiting` | `next: edit the file, then `hive <stage-verb> <slug>` again` |
| `:complete` | `next: hive plan <slug>`, `hive develop <slug>`, or `hive archive <slug>` depending on current stage; JSON keeps path fields and uses the workflow command |
| `:execute_complete` | `next: hive pr <slug>`; JSON keeps path fields and uses the workflow command |
| `:execute_stale` | `next: edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run` |
| `:error` | raises `Hive::TaskInErrorState` → `bin/hive` rescues → exit 3 (`TASK_IN_ERROR`). JSON mode emits the full payload first, then raises — dual signal. |

`next_stage_dir` increments `task.stage_index`; `7-done` has no `next:`.

## Stage routing

| Stage name | Runner | Page |
|-----------|--------|------|
| `inbox` | `Stages::Inbox` (inert) | [[stages/inbox]] |
| `brainstorm` | `Stages::Brainstorm` | [[stages/brainstorm]] |
| `plan` | `Stages::Plan` | [[stages/plan]] |
| `execute` | `Stages::Execute` | [[stages/execute]] |
| `review` | `Stages::Review` | [[stages/review]] |
| `pr` | `Stages::Pr` | [[stages/pr]] |
| `done` | `Stages::Done` | [[stages/done]] |

## Lock interactions

- **Task lock** (`<task folder>/.lock`) wraps the entire stage run, including the long-running claude subprocess. Lock contains `pid`, `started_at`, `process_start_time`, and gets `claude_pid` injected after spawn (used by `hive status` to detect stale agents).
- **Commit lock** (`<project>/.hive-state/.commit-lock`) is taken only during the post-run `git add && git commit` to serialize concurrent commits across multiple in-flight tasks.

See [[modules/lock]].

## Tests

Per-stage integration tests exercise the dispatcher end-to-end:

- `test/integration/run_brainstorm_test.rb`
- `test/integration/run_plan_test.rb`
- `test/integration/run_execute_test.rb`
- `test/integration/run_pr_test.rb`
- `test/integration/run_done_test.rb`
- `test/integration/full_flow_test.rb` (chains all stages)

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/status]] · [[commands/approve]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/review]] · [[stages/pr]] · [[stages/done]]
- [[modules/task]] · [[modules/lock]] · [[modules/markers]] · [[modules/git_ops]]

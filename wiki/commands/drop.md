---
title: hive drop
type: command
source: lib/hive/commands/drop.rb, web/app/models/concerns/task_mutations.rb, web/app/controllers/tasks/drops_controller.rb, web/config/routes.rb
created: 2026-05-22
updated: 2026-07-22
tags: [command, task, cleanup, json, tui, web]
---

**TLDR**: `hive drop TARGET [--project NAME] [--from STAGE] [--json]` hard-deletes an active task. It identity-checks the recorded agent with `.lock` start-time metadata (including `claude_pid_start_time`), kills that process plus descendant tool processes present in a successful process-tree snapshot, closes the draft PR best-effort, removes the task's worktree and branch, deletes the task folder from every active stage, removes per-slug logs, and records an audit commit on `hive/state`. There is no dropped bucket, archive, undo, reason prompt, or confirmation.

## Usage

```
hive drop my-task-260522-abcd
hive drop 7448
hive drop 7448 --project demo
hive drop my-task-260522-abcd --project demo --from 4-execute
hive drop /path/to/.hive-state/stages/4-execute/my-task-260522-abcd --json
```

Numeric task ids and path targets use [[modules/task_resolver]] lookup; bare
slugs use Drop's project/stage scan with the same `--project` and `--from`
scoping rules. Pass `--project` to disambiguate cross-project collisions and
`--from` to assert the current stage on retry.

## Refusals

Tasks at `9-done` are archive records — drop refuses them and leaves the folder alone.

| Case | Exit | `error_kind` |
|---|---:|---|
| Dropped successfully | 0 | — |
| Generic failure (uncategorised) | 1 | `error` |
| `--from` does not match the resolved active stage | 4 | `wrong_stage` |
| Unknown slug/path/id | 64 | `invalid_task_path` |
| Ambiguous slug/id across projects | 64 | `ambiguous_slug` |
| Task is already in `9-done` | 64 | `already_archived` |
| Git operation failed (e.g. `branch -D`) | 70 | `git` |
| Worktree operation failed (e.g. `worktree remove`) | 70 | `worktree` |
| Internal failure | 70 | `internal` |
| `hive/state` commit lock contention | 75 | `error` |
| Malformed project / global config | 78 | `config` |

`--from` only raises `wrong_stage` when the slug resolves unambiguously to a single project. For a cross-project slug collision with a mismatched `--from`, the user gets `ambiguous_slug` (or `invalid_task_path` when no project matches) — `--from` is asserted only after the project is pinned.

The exit-4 `wrong_stage` contract is **slug-only**. For numeric-id (and path) targets, `--from` flows through [[modules/task_resolver]] as a stage *filter*, so a mismatched stage means the id resolves to no task there: drop reports `invalid_task_path` (exit 64), not `wrong_stage` (exit 4). This keeps id targets consistent with their `run`/`approve`/`findings` siblings, which share the same resolver.

When a recorded draft PR exists but `gh` is not installed on PATH, draft-PR close is skipped with a warning on stderr (`pr_closed: false`, exit 0). Drop does not require `gh`. In the current v2 JSON contract, `pr_closed` is `true` whenever PR cleanup ends clean — including the common no-PR-recorded case — and `false` strictly means a recorded PR could not be closed (hivebox qualifies its "Dropped" notice on that signal). The v1 schema file remains for consumers pinned to the older no-PR-is-false interpretation.

## Steps Performed

`Hive::Commands::Drop#call` runs the cleanup in a fixed, idempotent order:

1. Resolve the task target (`TaskResolver` for paths/ids, Drop's project/stage scan for slugs).
2. Refuse archived-only tasks in `9-done`.
3. Kill recorded agent PIDs from `.lock` and `AGENT_WORKING pid=...`, guarded by process start time when available. In particular, `.lock`'s `claude_pid_start_time` verifies the recorded `claude_pid` identity before cleanup. Before signalling that root PID, snapshot its descendants, take a second full snapshot, and retain only PIDs whose parent, process group, and start-time identity match across both reads. This prevents PID reuse between process-table and identity reads from combining an old process's ancestry with a replacement process's identity. If either process-tree discovery fails, cleanup falls back to the recorded root PID only and reports `process_tree_unavailable` instead of claiming a complete tree cleanup.
4. Close `pr_url` from `pr.md` frontmatter with `gh pr close <url> --comment "task dropped"` best-effort.
5. Remove the task worktree from `worktree.yml` or the derived path, retrying with force when needed, then prune stale git worktree metadata.
6. Delete the task branch (`branch name == slug`) best-effort.
7. Remove the task folder from each active stage it was found in (`from_stages`), not a fixed `1-inbox`–`8-finalize` coding range — generic workflows have their own active stages.
8. Remove `.hive-state/logs/<slug>/`.
9. Commit an audit record on `hive/state` as `hive: dropped/<slug> dropped`.

Re-running after an interrupted cleanup converges: already-missing processes, folders, worktrees, PRs, and branches are treated as complete.

`agent_killed_pids` reports the recorded root candidates whose cleanup
succeeded. It does not enumerate the descendant PIDs terminated as part of that
root's process tree. `agent_killed` is true when
at least one recorded candidate was cleaned up, so
`agent_kill_skipped_reason` can be non-null alongside it when another candidate
was skipped or only received incomplete cleanup. A
`process_tree_unavailable` reason means the recorded root cleanup was attempted
but descendant discovery could not be completed.

The descendant set is captured and identity-confirmed across two consecutive
snapshots. A process forked after confirmation can escape that cleanup window;
closing that residual race requires durable
OS-level containment (for example, a cgroup or equivalent process-lifetime
boundary), not another assertion around the snapshot algorithm.

## JSON Contract

Success emits `schema = "hive-drop"`, current version 2:

```json
{
  "schema": "hive-drop",
  "schema_version": 2,
  "ok": true,
  "slug": "my-task-260522-abcd",
  "project": "demo",
  "from_stages": ["4-execute"],
  "pr_closed": false,
  "worktree_removed": true,
  "branch_deleted": true,
  "agent_killed": true,
  "agent_pid": 12345,
  "agent_killed_pids": [12345],
  "agent_kill_skipped_reason": null,
  "commit_action": "committed"
}
```

Errors use `Hive::Schemas::ErrorEnvelope.build` under the same `hive-drop` schema. External consumers should resolve the current file via `Hive::Schemas.schema_path("hive-drop")`, which now points at v2; `Hive::Schemas.schema_path("hive-drop", version: 1)` remains available for pinned v1 validators.

## TUI Binding

In [[commands/tui]], Shift+X drops the focused right-pane row by dispatching:

```
hive drop <slug> --project <project> --from <stage> --json
```

Lowercase `x` is intentionally unbound. The archived-row and empty-grid cases flash a refusal and do not spawn the command.

## Web Binding

This binding reflects queued Rails resource commit `153bed1d`
(patch-equivalent to `96b06792` / `2fef1f47`); current-default integration is
tracked in [[gaps]].

In [[commands/web]], the task page's Advanced section posts its Drop card to:

```
POST /tasks/:project/:slug/drop
```

`Tasks::DropsController#create` loads the filesystem-backed `Task` and calls
`Task#drop!`, which constructs the same `Hive::Commands::Drop` command
in-process with `project:` and the rendered row stage as `from:`. The `from`
parameter is load-bearing: a stale page whose
task already moved to another stage raises `Hive::WrongStage`, which the Rails
error handler renders as 422, leaving the moved task intact. On success the page
redirects to the status grid because the detail page no longer has a task to
show.

## Backlinks

- [[cli]] · [[commands/tui]] · [[commands/status]] · [[commands/web]]
- [[modules/git_ops]] · [[modules/worktree]] · [[modules/lock]]

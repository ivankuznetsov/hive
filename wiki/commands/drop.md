---
title: hive drop
type: command
source: lib/hive/commands/drop.rb
created: 2026-05-22
updated: 2026-05-22
tags: [command, task, cleanup, json, tui]
---

**TLDR**: `hive drop TARGET [--project NAME] [--from STAGE] [--json]` hard-deletes an active task. It kills any recorded agent process, closes the draft PR best-effort, removes the task's worktree and branch, deletes the task folder from every active stage, removes per-slug logs, and records an audit commit on `hive/state`. There is no dropped bucket, archive, undo, reason prompt, or confirmation.

## Usage

```
hive drop my-task-260522-abcd
hive drop my-task-260522-abcd --project demo --from 4-execute
hive drop /path/to/.hive-state/stages/4-execute/my-task-260522-abcd --json
```

Bare slugs use [[modules/task_resolver]] lookup. Pass `--project` to disambiguate cross-project collisions and `--from` to assert the current stage on retry.

## Refusals

Tasks at `9-done` are archive records — drop refuses them and leaves the folder alone.

| Case | Exit | `error_kind` |
|---|---:|---|
| Dropped successfully | 0 | — |
| Generic failure (uncategorised) | 1 | `error` |
| `--from` does not match the resolved active stage | 4 | `wrong_stage` |
| Unknown slug/path | 64 | `invalid_task_path` |
| Ambiguous slug across projects | 64 | `ambiguous_slug` |
| Task is already in `9-done` | 64 | `already_archived` |
| Git operation failed (e.g. `branch -D`) | 70 | `git` |
| Worktree operation failed (e.g. `worktree remove`) | 70 | `worktree` |
| Internal failure | 70 | `internal` |
| `hive/state` commit lock contention | 75 | `error` |
| Malformed project / global config | 78 | `config` |

`--from` only raises `wrong_stage` when the slug resolves unambiguously to a single project. For a cross-project slug collision with a mismatched `--from`, the user gets `ambiguous_slug` (or `invalid_task_path` when no project matches) — `--from` is asserted only after the project is pinned.

When `gh` is not installed on PATH, draft-PR close is skipped silently (warning on stderr, `pr_closed: false`, exit 0). Drop does not require `gh`.

## Steps Performed

`Hive::Commands::Drop#call` runs the cleanup in a fixed, idempotent order:

1. Resolve the task via [[modules/task_resolver]].
2. Refuse archived-only tasks in `9-done`.
3. Kill recorded agent PIDs from `.lock` and `AGENT_WORKING pid=...`, guarded by process start time when available.
4. Close `pr_url` from `pr.md` frontmatter with `gh pr close <url> --comment "task dropped"` best-effort.
5. Remove the task worktree from `worktree.yml` or the derived path, retrying with force when needed, then prune stale git worktree metadata.
6. Delete the task branch (`branch name == slug`) best-effort.
7. Remove every active-stage folder matching the slug under `1-inbox` through `8-finalize`.
8. Remove `.hive-state/logs/<slug>/`.
9. Commit an audit record on `hive/state` as `hive: dropped/<slug> dropped`.

Re-running after an interrupted cleanup converges: already-missing processes, folders, worktrees, PRs, and branches are treated as complete.

## JSON Contract

Success emits `schema = "hive-drop"`, version 1:

```json
{
  "schema": "hive-drop",
  "schema_version": 1,
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

Errors use `Hive::Schemas::ErrorEnvelope.build` under the same `hive-drop` schema. External consumers validate against `schemas/hive-drop.v1.json`; resolve via `Hive::Schemas.schema_path("hive-drop")`.

## TUI Binding

In [[commands/tui]], Shift+X drops the focused right-pane row by dispatching:

```
hive drop <slug> --project <project> --from <stage> --json
```

Lowercase `x` is intentionally unbound. The archived-row and empty-grid cases flash a refusal and do not spawn the command.

## Backlinks

- [[cli]] · [[commands/tui]] · [[commands/status]]
- [[modules/git_ops]] · [[modules/worktree]] · [[modules/lock]]

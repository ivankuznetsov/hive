---
title: hive drop
type: command
source: lib/hive/commands/drop.rb, web/app/models/task.rb, web/app/models/concerns/task_mutations.rb, web/app/controllers/tasks/drops_controller.rb, web/config/routes.rb
created: 2026-05-22
updated: 2026-09-02
tags: [command, task, cleanup, json, tui, web]
---

**TLDR**: `hive drop TARGET [--project NAME] [--from STAGE] [--json]`
hard-deletes an active task. It identity-checks the agent recorded in the typed
task lease, kills that process plus identity-stable descendants, fences the
remaining destructive work with the project commit lock and deterministic
task leases, closes the draft PR best-effort, removes worktree/branch/folders/
logs, and records an audit commit on `hive/state`. There is no dropped bucket,
archive, undo, reason prompt, or confirmation.

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
| Replacement task runner wins the cleanup race | 75 | `error` |
| Malformed project / global config | 78 | `config` |

`--from` only raises `wrong_stage` when the slug resolves unambiguously to a single project. For a cross-project slug collision with a mismatched `--from`, the user gets `ambiguous_slug` (or `invalid_task_path` when no project matches) — `--from` is asserted only after the project is pinned.

The exit-4 `wrong_stage` contract is **slug-only**. For numeric-id (and path) targets, `--from` flows through [[modules/task_resolver]] as a stage *filter*, so a mismatched stage means the id resolves to no task there: drop reports `invalid_task_path` (exit 64), not `wrong_stage` (exit 4). This keeps id targets consistent with their `run`/`approve`/`findings` siblings, which share the same resolver.

Pre-dispatch usage failures use the same `hive-drop.v2` error envelope with
`error_kind: "invalid_task_path"`. If command-level error-envelope encoding
raises `JSON::GeneratorError`, drop warns on stderr, emits no substitute
document, and re-raises the original typed failure.

When a recorded draft PR exists but `gh` is not installed on PATH, draft-PR close is skipped with a warning on stderr (`pr_closed: false`, exit 0). Drop does not require `gh`. In the current v2 JSON contract, `pr_closed` is `true` whenever PR cleanup ends clean — including the common no-PR-recorded case — and `false` strictly means a recorded PR could not be closed (hivebox qualifies its "Dropped" notice on that signal). The v1 schema file remains for consumers pinned to the older no-PR-is-false interpretation.

## Steps Performed

`Hive::Commands::Drop#call` runs the cleanup in a fixed, idempotent order:

1. Resolve the target and refuse archived-only tasks.
2. Enter the project `.commit-lock`, then read the current typed lease and
   marker identities.
3. Kill recorded agent roots from the lease and `AGENT_WORKING pid=...`,
   guarded by process start time. Descendants are retained only when parent,
   group, and start identity match across two process snapshots. Failed tree
   discovery falls back to the verified root and reports
   `process_tree_unavailable`.
4. Acquire every observed task lease in deterministic folder order. A runner
   that starts after process cleanup but before this claim wins the lease and
   aborts Drop before deletion.
5. Re-resolve and revalidate folder/stage context while the commit lock and
   task leases are held.
6. Close `pr_url` best-effort; remove owned worktree and branch; delete every
   active-stage folder and `.hive-state/logs/<slug>/`; then commit
   `hive: dropped/<slug> dropped`.

The logical leases remain held across this external work, but no SQLite
transaction remains open while GitHub, process, filesystem, or Git operations
run.

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

## Serialization fallback

Drop encodes both success and error arms directly as `hive-drop.v2`. A
`JSON::GeneratorError` is raised; Hive emits no prose or fallback JSON document.

## TUI Binding

In [[commands/tui]], Shift+X drops the focused right-pane row by dispatching:

```
hive drop <slug> --project <project> --from <stage> --json
```

Lowercase `x` is intentionally unbound. The archived-row and empty-grid cases flash a refusal and do not spawn the command.

## Web Binding

In [[commands/web]], the task page's Advanced section posts its Drop card to:

```
POST /tasks/:project/:slug/drop
```

`Tasks::DropsController#create` loads the filesystem-backed `Task` and calls
`Task#drop!`, which constructs the
same `Hive::Commands::Drop` command in-process with `project:` and the rendered
row stage as `from:`. The `from` parameter is load-bearing: a stale page whose
task already moved to another stage raises `Hive::WrongStage`, which the Rails
error handler renders as 422, leaving the moved task intact. On success the page
redirects to the status grid because the detail page no longer has a task to
show.

## Backlinks

- [[cli]] · [[commands/tui]] · [[commands/status]] · [[commands/web]]
- [[modules/git_ops]] · [[modules/worktree]] · [[modules/lock]]

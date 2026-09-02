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
task lease, cleans that recorded process plus identity-stable descendants, and
fences the remaining destructive work with the project commit lock and
deterministic task leases. An unresolved `kill_failed` candidate aborts before
those leases or any PR/worktree/branch/task/log deletion. Successful Drop
closes the draft PR best-effort, removes worktree/branch/folders/logs, and
records an audit commit on `hive/state`. There is no dropped bucket, archive,
undo, reason prompt, or confirmation.

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
| Any recorded candidate returns `kill_failed` | 75 | `error` |
| Malformed project / global config | 78 | `config` |

`--from` only raises `wrong_stage` when the slug resolves unambiguously to a single project. For a cross-project slug collision with a mismatched `--from`, the user gets `ambiguous_slug` (or `invalid_task_path` when no project matches) — `--from` is asserted only after the project is pinned.

The exit-4 `wrong_stage` contract is **slug-only**. For numeric-id (and path) targets, `--from` flows through [[modules/task_resolver]] as a stage *filter*, so a mismatched stage means the id resolves to no task there: drop reports `invalid_task_path` (exit 64), not `wrong_stage` (exit 4). This keeps id targets consistent with their `run`/`approve`/`findings` siblings, which share the same resolver.

When a recorded draft PR exists but `gh` is not installed on PATH, draft-PR close is skipped with a warning on stderr (`pr_closed: false`, exit 0). Drop does not require `gh`. In the current v2 JSON contract, `pr_closed` is `true` whenever PR cleanup ends clean — including the common no-PR-recorded case — and `false` strictly means a recorded PR could not be closed (hivebox qualifies its "Dropped" notice on that signal). The v1 schema file remains for consumers pinned to the older no-PR-is-false interpretation.

## Steps Performed

`Hive::Commands::Drop#call` runs the cleanup in a fixed, idempotent order:

1. Resolve the target and refuse archived-only tasks.
2. Enter the project `.commit-lock`, then read the current typed lease and
   marker identities.
3. Attempt cleanup of recorded agent roots from the lease and
   `AGENT_WORKING pid=...`,
   guarded by process start time when one was recorded. Exact PID/start-time
   duplicates collapse, but different recorded start times for a reused PID
   remain separate candidates across task folders. A readable initial
   mismatch returns `pid_reuse_guard` without signalling. After TERM, a
   readable replacement proves the recorded process exited and completes
   without KILL; an unavailable identity, including an identity-source I/O
   failure, succeeds only when one liveness check finds the PID absent,
   otherwise it returns `kill_failed`. A matching identity
   alone may receive KILL, and the same replacement/unavailable/match decision
   is retained after the KILL grace period. Descendants are retained only when
   parent, group, and start identity match across two process snapshots. Failed
   tree discovery falls back to the verified root and reports
   `process_tree_unavailable`.
4. If any candidate returned `kill_failed`, abort with retryable exit 75 before
   acquiring task leases or changing the recorded PR, worktree, branch, task
   folder, logs, lease/marker identity, or hive-state audit history. Restore
   start-time visibility or stop and verify the recorded process, then rerun the
   ordinary Drop command. A successful candidate or an earlier non-gating
   reason cannot hide this fence.
5. Acquire every observed task lease in deterministic folder order. A runner
   that starts after process cleanup but before this claim wins the lease and
   aborts Drop before deletion.
6. Re-resolve and revalidate folder/stage context while the commit lock and
   task leases are held.
7. Close `pr_url` best-effort; remove owned worktree and branch; delete every
   active-stage folder and `.hive-state/logs/<slug>/`; then commit
   `hive: dropped/<slug> dropped`.

The logical leases remain held across this external work, but no SQLite
transaction remains open while GitHub, process, filesystem, or Git operations
run.

Re-running after an interrupted cleanup converges: already-missing processes,
folders, worktrees, PRs, and branches are treated as complete. A `kill_failed`
refusal intentionally leaves the recorded task identity and destructive
resources in place for remediation and the same retry.

`agent_killed_pids` reports the recorded root candidates whose cleanup
succeeded. It does not enumerate the descendant PIDs terminated as part of that
root's process tree. A post-TERM or post-KILL replacement success remains in
this v2 compatibility list under its recorded numeric PID, even though that
number may now identify an unrelated live replacement. The field is audit
context only and must never be reused as a signalling list. `agent_killed` is
true when at least one recorded identity was cleaned up; it does not claim that
SIGKILL, or any signal at all, was sent. Consequently,
`agent_kill_skipped_reason` can be non-null alongside it when another candidate
was skipped or only received incomplete cleanup. A
`process_tree_unavailable` reason means the recorded root cleanup was attempted
but descendant discovery could not be completed.

Marker-only and older records without a usable process start time retain the
legacy liveness-only TERM-to-KILL path. They are outside the replacement-PID
suppression guarantee. `claude_pid` candidates continue through
`terminate_process_group`, whose initial unavailable-lookup compatibility and
tree-snapshot behavior are unchanged; `process_tree_unavailable` does not
inherit the single-PID replacement-success semantics.

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

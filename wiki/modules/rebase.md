---
title: Hive::Rebase
type: module
source: lib/hive/rebase.rb
created: 2026-05-14
updated: 2026-05-14T12:00:00Z
tags: [rebase, orchestrator, git, agent-dispatch, fail-soft]
---

**TLDR**: Orchestrator-side auto-rebase pre-step for `hive run`. Before dispatching the stage runner, `Hive::Rebase.perform(task, cfg)` detects whether the task's worktree branch is behind `origin/<default_branch>`, fetches with non-interactive env, attempts `git rebase`, and dispatches the project's execute-stage agent (`cfg.execute.agent`, isolated to the worktree via `add_dirs: []`) to resolve any conflicts. Fail-soft: any failure aborts the rebase, cleans agent-created untracked files via `git reset --hard ORIG_HEAD && git clean -fd`, and proceeds with the stale base. Originally added to close the REVIEW_STALE drift loop where long-running tasks accumulated phantom-deletion escalations after main moved forward. Plan: `docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md`.

## Public API

- **`Hive::Rebase.perform(task, cfg) -> Hive::Rebase::Result`** — the only public entry point. `task` is a `Hive::Task`-shaped object that responds to `worktree_path` and `folder`. `cfg` is the project config Hash. Never raises (narrow rescue catches `Hive::GitError`, `SystemCallError`, `IOError`; programmer errors deliberately escape).

- **`Hive::Rebase::Result`** — Data.define with 7 fields:
  - `attempted` (boolean) — true once the rebase machinery ran past the disabled/no-worktree guards.
  - `commits_behind` (Integer or nil) — how far behind `origin/<default>` the worktree was, or nil when the rebase was skipped before commit counting.
  - `succeeded` (boolean) — true on clean rebase (or no-op when `commits_behind == 0`).
  - `agent_resolutions` (Integer) — count of conflict-resolution agent dispatches.
  - `resolved_files` (Array<String>) — files the agent touched during resolution.
  - `reason` (Symbol or nil) — `nil` on success; a closed-set Symbol naming the skip-or-failure cause otherwise. See [[commands/run]] for the full enum.
  - `post_rebase_warnings` (Array<String>) — non-fatal warnings produced after a successful rebase (e.g., `worktree.yml execute_base_head` write failure). Empty on clean success.

- **`Hive::Rebase::MAX_CONFLICT_RESOLUTIONS = 5`** — hardcoded cap on conflict-resolution agent dispatches per `perform` invocation. Not configurable per the doc-review's S1 decision: projects with persistently high-conflict branches should investigate the underlying drift, not raise the cap.

- **`Hive::RebaseConflict < Hive::GitError`** (lib/hive.rb) — raised by `GitOps#rebase_onto` / `#rebase_continue` when git halts with conflicts. Distinct from generic `GitError` so callers can rescue conflicts without swallowing unrelated git failures.

## Internals

### Pre-rebase guards (in order)

The guards short-circuit before any git fetch or rebase attempt. Each maps to a specific `Result.reason`:

1. `cfg.rebase.enabled == false` → `:disabled`
2. `@no_rebase` CLI override → `:cli_override` (handled in `Hive::Commands::Run`, not `Rebase.perform`)
3. `task.worktree_path` missing or directory absent → `:no_worktree`
4. `.git/rebase-merge/` or `.git/rebase-apply/` exists (pre-existing half-rebase) → `:pre_existing_rebase`
5. Worktree dirty (any uncommitted changes) → `:dirty_worktree`
6. Detached HEAD → `:detached_head`
7. Default branch cannot be resolved from cfg or git → `:no_default_branch`

### Fetch

`git fetch origin <default_branch>` runs with:
- `GIT_TERMINAL_PROMPT=0` (kills HTTPS credential prompts)
- `GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=10"` (kills SSH host-key / credential prompts)
- Ruby-side wall-clock budget `GitOps::FETCH_TIMEOUT_SEC = 60` via `Process.spawn` + `Process.waitpid2` polling with SIGTERM→SIGKILL escalation

Failure (network, auth, timeout, unknown ref) → `:fetch_failed`. The fetch never raises — it returns `false` and the orchestrator routes to the skip path.

### Conflict-resolution loop

When `git rebase <origin/default>` raises `Hive::RebaseConflict`:

1. For each conflicting commit replay (up to `MAX_CONFLICT_RESOLUTIONS = 5`):
   1. Read `staged_unmerged_files` from git.
   2. If empty (defensive — rebase says in-progress but nothing unmerged), call `rebase_continue` and loop.
   3. Dispatch `Hive::Stages::Base.spawn_agent(task, ...)` with:
      - `profile: stage_profile(cfg, "execute")` — uses the project's configured execute-stage agent.
      - `cwd: task.worktree_path` — git rebase state lives in the worktree.
      - `add_dirs: []` — security boundary; agent physically cannot reach `task.folder` (`plan.md`, `worktree.yml`, `task.md` are unreachable regardless of prompt content).
      - `timeout_sec: cfg.rebase.conflict_resolution_timeout_sec` (default `2700`).
      - `max_budget_usd: cfg.budget_usd.execute_implementation || 500`.
      - `prompt:` rendered from `templates/rebase_conflict_resolution.md.erb` with the commit message + conflict file paths + file contents inside a per-spawn `<user_supplied_<hex>>` nonce block (ADR-008/019).
   4. After the agent returns:
      - If `status != :ok` → abort with `:agent_failed`.
      - If `rebase_in_progress?` is now false:
        - Check if the agent completed the rebase cleanly (no markers, worktree clean). If yes, **accept** the work (PR #69 review B9). If no, abort with `:agent_called_continue_itself`.
      - If conflict markers still in any resolved file → abort with `:markers_remaining`. The marker check **fails closed** (returns true on read error) so unreadable files default to abort.
   5. `rebase_continue` advances to the next commit; if it raises `RebaseConflict`, loop. If it raises `GitError` / `SystemCallError` / `IOError`, abort with `:rebase_continue_failed`.

`MAX_CONFLICT_RESOLUTIONS` exceeded → `:max_attempts_exceeded`.

### Abort path

Every failure runs `abort_with(reason)` which:
1. `git rebase --abort` — restores tracked files to pre-rebase HEAD.
2. `git reset --hard ORIG_HEAD && git clean -fd` — removes agent-created untracked files (`--abort` alone doesn't clean them; this combo is the actual primitive).

Return value: `Result.failed(reason, commits_behind, attempts - 1, resolved_files)` so the orchestrator continues against the (pre-rebase) base.

### Successful rebase: `execute_base_head` rewrite

After a successful rebase, `update_execute_base_head!(task, git, warnings)` rewrites `worktree.yml`'s `execute_base_head` to the post-rebase HEAD SHA via atomic temp-file + rename. Without this, 4-execute continuation passes trip `EXECUTE_WAITING(reason=head_not_descendant)` because the stored pre-rebase SHA is no longer reachable in the rebased commit graph.

If the rewrite itself fails (malformed YAML, I/O error, rename failure), a stderr warning fires AND the failure lands in `Result.post_rebase_warnings` — the JSON envelope consumer can see exactly which post-success step broke, even though the rebase itself succeeded.

## Security boundaries

- **Per-spawn nonce wrap** (ADR-008/019): every conflict-resolution agent gets a fresh `<user_supplied_<hex>>` block around the conflict context. 64 bits of entropy per spawn; a pre-committed payload in main or the worktree cannot construct the closing tag.
- **`add_dirs: []` isolation**: the agent's filesystem grant is empty; it physically cannot reach `task.folder`. The `Hive::ProtectedFiles::ORCHESTRATOR_OWNED` files live there, not in the worktree git tree — they cannot appear in `staged_unmerged_files` by construction. The original PR #69 had a belt-and-suspenders basename check against these files in `resolve_conflicts` but it was removed (B8) after the doc-review identified it as a false-positive generator (any project file named `plan.md` at the worktree root would have aborted the rebase) without adding real security.
- **Orchestrator vs agent SHA contract**: `Hive::Rebase.perform` runs in the orchestrator and is allowed to mutate `worktree.yml` (the SHA snapshot lives only around agent spawns). The conflict-resolution agent spawn re-enters the SHA contract — but `add_dirs: []` makes this moot since the agent can't reach the protected files anyway.

## Operational latency budget

Worst case: `MAX_CONFLICT_RESOLUTIONS × cfg.rebase.conflict_resolution_timeout_sec` = `5 × 2700s` = `13500s` (~3.75 hours) of `Hive::Lock.with_task_lock` occupation. `Hive::Lock` is fail-fast (raises `ConcurrentRunError` immediately, no wait), so concurrent `hive run` / TUI / daemon dispatches against the same task hard-error during this entire window. Accepted trade-off for v1 — see [[commands/run]] "Auto-rebase pre-step" for the explicit acknowledgement and recovery paths.

`rebase_onto` and `rebase_continue` themselves have a per-op timeout (`GitOps::REBASE_OP_TIMEOUT_SEC = 300s`) so a stalled commit-hook can't extend the worst case indefinitely. With timeout escalation: SIGTERM → 0.5s grace → SIGKILL → reap.

## Read-only inspector

`hive rebase-status TARGET` (Hive::Commands::RebaseStatus) reports whether the next `hive run` would attempt a rebase, how far behind, and what guards would short-circuit — without mutating anything (no `git fetch` even). See [[commands/rebase-status]] for the CLI surface and JSON envelope.

## Backlinks

- [[commands/run]] — the consumer; "Auto-rebase pre-step" subsection documents every reason in the closed enum.
- [[commands/rebase-status]] — read-only inspector.
- [[modules/git_ops]] — `GitOps#rebase_onto`, `#rebase_continue`, `#rebase_abort`, `#rebase_in_progress?`, `#staged_unmerged_files`, `#reset_hard_orig_head`, `#fetch_default_branch`, `#commits_behind`, `#rebase_merge_message_path`.
- [[stages/execute]] — `execute_base_head` is the worktree.yml field U8 rewrites after success.
- [[decisions]] — ADR for additive schema fields (required vs optional).

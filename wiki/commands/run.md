---
title: hive run
type: command
source: lib/hive/commands/run.rb
created: 2026-04-25
updated: 2026-05-22T13:30:00Z
tags: [command, dispatcher, stages, json, rebase]
---

**TLDR**: `hive run TARGET` is the lower-level dispatcher for a slug or task folder. It resolves `TARGET` into a `Hive::Task`, takes the per-task lock, attempts an auto-rebase pre-step against the project's default branch (fail-soft), picks the matching stage runner, executes it, commits any `.hive-state` changes via the per-project commit lock, and reports the resulting marker plus a workflow-oriented `next:` hint. Most humans should start with `hive status` and use `hive brainstorm|plan|develop|open-pr|review|finalize|archive <slug>`.

## Usage

```
hive run <slug> [--project NAME] [--stage STAGE] [--json] [--no-rebase]
hive run <project>/.hive-state/stages/<N>-<stage>/<slug> [--json] [--no-rebase]
```

`TARGET` is resolved by `Hive::TaskResolver`. Bare slugs search registered projects; `--project` scopes cross-project collisions; `--stage` scopes same-slug stage collisions. Folder paths remain exact and authoritative.

`--no-rebase` is a one-off override that skips the auto-rebase pre-step for this run only — useful when a long-running rebase is undesirable for an unblock or when troubleshooting the rebase machinery itself. The persistent off-switch lives in config (`rebase.enabled: false`). When `--no-rebase` is set, the JSON envelope's `rebase.reason` is `"cli_override"` (distinct from the config-driven `"disabled"`).

## Steps performed (`Commands::Run#call`)

1. Resolve `TARGET` via `Hive::TaskResolver` and load merged config via `Hive::Config.load(task.project_root)`.
2. Acquire the per-task lock via `Hive::Lock.with_task_lock` with payload `{slug:, stage:}`. Concurrent run → `ConcurrentRunError` (exit 75, `TEMPFAIL`, stderr `hive: another hive run is active`).
3. If the current marker is `MANUAL_STEERING`, skip before auto-rebase or runner dispatch and report `marker=manual_steering` with `next_action.kind=no_op`. JSON sets `rebase.reason="manual_steering"`.
4. **Auto-rebase pre-step** (`Hive::Rebase.perform`): see "Auto-rebase pre-step" below.
5. `pick_runner(task)` returns one of `Hive::Stages::{Inbox,Brainstorm,Plan,Execute,OpenPr,Review,Artifacts,Finalize,Done}.method(:run!)`. Unknown stage → `StageError`.
6. Call the runner inside `Hive::Stages::Base.with_stage_events(task) { runner.call(task, cfg) }`. The wrapper emits a `stage_enter` event before the call, a `stage_exit` event after it, plus marker-driven `round_waiting` / `round_complete` (brainstorm, plan) or `error` (any error-class marker) events between them. Any raise emits a paired `error` + `stage_exit` so `events.jsonl` brackets stay balanced. See [[modules/events]].
7. `commit_after`: if `result[:commit]`, take the per-project commit lock and run `GitOps#hive_commit(stage_name: "<N>-<stage>", slug:, action: result[:commit])`.
8. `report`: print the current marker, the state file path, and a stage-aware next step.

## Auto-rebase pre-step (`Hive::Rebase.perform`)

`hive run` checks whether the task's worktree branch is behind `origin/<default_branch>` and, if so, attempts a rebase before dispatching the stage runner. This prevents the failure mode where a long-running task's branch drifts behind main and reviewers in 5-review see "phantom deletions" of code that landed on main after the branch was created (originating incident: `i-want-to-be-able-260507-7682` at REVIEW_STALE pass=4).

**Trigger:** stages 4-execute, 5-open-pr, 6-review, 7-artifacts, and 8-finalize. Stages 2-brainstorm and 3-plan have no worktree (`task.worktree_path` is nil), so the trigger silently no-ops; 1-inbox doesn't enter `hive run`; 9-done is terminal.

**Pre-rebase guards (in order, before any fetch):**
1. `cfg.rebase.enabled == false` → `Result.disabled`.
2. `task.worktree_path` missing → `Result.skipped(:no_worktree)`.
3. `.git/rebase-merge/` or `.git/rebase-apply/` directory exists (pre-existing half-rebase from a prior aborted run) → `Result.skipped(:pre_existing_rebase)`. Emits a louder stderr warning naming the manual recovery: `cd <worktree_path> && git rebase --abort`.
4. Worktree dirty → `Result.skipped(:dirty_worktree)`.
5. Detached HEAD → `Result.skipped(:detached_head)`.

**Fetch:** `git fetch origin <default_branch>` runs with `GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=10"` set in the spawn environment, plus a Ruby-side wall-clock budget (`FETCH_TIMEOUT_SEC = 60`) enforced via `Process.spawn` + `Process.waitpid2` polling with SIGTERM→SIGKILL escalation. So both credential/host-key prompts and HTTPS network hangs fail immediately rather than blocking the run. Failure → `Result.skipped(:fetch_failed)`.

**Conflict-resolution agent:** when `git rebase` halts with conflicts, `Hive::Rebase` dispatches the project's `cfg.execute.agent` profile via `Hive::Stages::Base.spawn_agent` with:
- `cwd: task.worktree_path` (the rebase state lives in the worktree)
- `add_dirs: []` (the agent is isolated from `task.folder` — it physically cannot touch `plan.md`/`worktree.yml`/`task.md`)
- `status_mode: :exit_code_only` (conflict resolution is development work, not a reviewer artifact; Hive validates git state and marker bytes after the agent exits)
- `timeout_sec: cfg.rebase.conflict_resolution_timeout_sec` (default 2700)
- prompt rendered from `templates/rebase_conflict_resolution.md.erb` with the conflict files wrapped in a per-spawn `<user_supplied_<hex>>` nonce block (ADR-008/019)
- bounded by `Hive::Rebase::MAX_CONFLICT_RESOLUTIONS = 5` agent dispatches per rebase invocation (not configurable; projects with persistent high-conflict branches should investigate the drift, not raise the cap)

Protected-file basename guard (originally present pre-merge) was **removed** during the PR-#69 review. The `add_dirs: []` isolation makes `task.folder`'s protected files (`plan.md`, `worktree.yml`, `task.md`) physically unreachable to the agent — they cannot appear in `staged_unmerged_files` by construction. The basename check was unreachable AND a false-positive generator (any project file genuinely named `plan.md` at the worktree root would have aborted the rebase needlessly). The constant `Hive::ProtectedFiles::ORCHESTRATOR_OWNED` is kept as a frozen empty list for backward source-compat.

**Fail-soft contract.** Any failure (agent non-zero exit, agent leaves conflict markers, agent runs `git rebase --continue` itself without completing the rebase, max attempts exceeded, fetch failure, unexpected I/O error) triggers `git rebase --abort` followed by `git reset --hard ORIG_HEAD && git clean -fd` (which removes agent-created untracked files that `--abort` doesn't clean). The worktree returns to its pre-rebase HEAD. The stage runner then proceeds against the (stale) base. **Agent-completed-the-rebase exception** (B9 fix): if the agent runs `git rebase --continue` itself and the rebase finishes cleanly (no in-progress state, no conflict markers in resolved files, worktree clean), the work is accepted instead of being thrown away.

**Successful-rebase post-step (U8).** When the rebase completes cleanly, `Hive::Rebase` rewrites `worktree.yml`'s `execute_base_head` to the post-rebase HEAD SHA. Without this, 4-execute continuation passes would trip `EXECUTE_WAITING(reason=head_not_descendant)` because the stored pre-rebase SHA is no longer reachable in the rebased commit graph. If this rewrite fails (malformed YAML, I/O error, rename failure), the failure is surfaced in `Result.post_rebase_warnings` AND on stderr — the rebase still counts as a success, but the JSON envelope tells consumers exactly which post-success step broke.

**Per-op timeouts.** Both `git rebase <ref>` and `git rebase --continue` are wrapped by `GitOps#run_git_with_timeout` with a 5-minute budget (`REBASE_OP_TIMEOUT_SEC = 300`). On timeout the child gets SIGTERM, then SIGKILL after a 0.5s grace, and is reaped. A stalled commit-hook can no longer extend the worst-case latency window indefinitely. Captured stderr is bounded by `GIT_CAPTURE_MAX_BYTES = 1 << 20` (1 MiB) so a runaway hook can't blow up the runner's memory either.

**Lock-window trade-off (accepted v1).** `Hive::Rebase.perform` runs entirely inside `Hive::Lock.with_task_lock`. The worst-case latency is `MAX_CONFLICT_RESOLUTIONS × cfg.rebase.conflict_resolution_timeout_sec` = `5 × 2700s` ≈ `3.75 hours` of lock occupation. `Hive::Lock` is fail-fast — concurrent `hive run` invocations against the same task hard-error with `ConcurrentRunError` (exit 75) during this entire window; the daemon honors that and skips. Acknowledged trade-off: the alternative (rebasing outside the lock) introduces races where two runs against the same task could both win the rebase and stomp on each other. The per-op `REBASE_OP_TIMEOUT_SEC` keeps any single git call bounded so a single bad hook cannot extend the window further. The `--no-rebase` flag gives operators an explicit escape hatch when they don't want the auto-rebase ceremony for a given run.

**Operator-visible signals.** Successful rebase emits `[hive] rebased N commits from origin onto <slug> branch [(K conflicts resolved by agent)]` to stderr. Any failure emits `[hive] rebase attempt failed (<reason>); continuing with stale base. Manual rebase recommended: cd <worktree_path> && git rebase origin/<default-branch>`.

**Per-project disable.** Set `rebase.enabled: false` in `<project>/.hive-state/config.yml` to opt out. The trigger becomes a silent no-op (`Result.disabled`).

**Read-only inspector.** `hive rebase-status TARGET` reports the same guard ladder without mutating anything (no `git fetch` even). See [[commands/rebase-status]].

**JSON envelope (`hive run --json`).** The `SuccessPayload` always includes a `rebase` block:

```json
{
  "rebase": {
    "attempted": true,
    "commits_behind": 3,
    "succeeded": true,
    "agent_resolutions": 1,
    "resolved_files": ["src/foo.rb"],
    "reason": null,
    "post_rebase_warnings": []
  }
}
```

`reason` is `null` on success and a snake-case string (closed enum, validated by `schemas/hive-run.v1.json`) otherwise. The full set:

| Reason | Meaning |
|--------|---------|
| `disabled` | `cfg.rebase.enabled = false` in this project |
| `cli_override` | `--no-rebase` was passed for this run |
| `no_worktree` | Stage has no worktree (brainstorm/plan) or worktree directory missing |
| `pre_existing_rebase` | `.git/rebase-merge/` or `.git/rebase-apply/` already exists; operator cleanup required |
| `dirty_worktree` | Uncommitted changes; rebase requires a clean tree |
| `detached_head` | Worktree HEAD is detached; nothing to rebase |
| `no_default_branch` | Default branch couldn't be resolved from cfg or git |
| `fetch_failed` | `git fetch origin <default>` failed (network/auth/timeout) |
| `manual_steering` | The task carries `MANUAL_STEERING`; `hive run` skipped before rebase and runner dispatch |
| `no_conflict_agent_configured` | `cfg.execute.agent` is missing (sanity guard) |
| `agent_failed` | Conflict-resolution agent returned non-OK status |
| `markers_remaining` | Agent finished but left conflict markers in a resolved file (also: read error reading the file — fails closed) |
| `agent_called_continue_itself` | Agent ran `git rebase --continue` itself and the rebase did NOT complete cleanly |
| `max_attempts_exceeded` | More than `MAX_CONFLICT_RESOLUTIONS = 5` conflict batches |
| `rebase_failed` | `git rebase` returned a non-conflict failure |
| `rebase_continue_failed` | `git rebase --continue` raised a non-conflict failure |
| `unexpected_io_error` | A `Hive::GitError` / `SystemCallError` / `IOError` escaped the narrow rescue (programmer-error class) |

`post_rebase_warnings` is always an array. Empty on clean success; populated when a successful rebase's post-step (e.g., `worktree.yml execute_base_head` rewrite) hit a non-fatal warning. The rebase itself still counts as `succeeded: true` — the warnings record exactly which downstream step failed.
## next: hints (by marker)

| Marker | `report` output |
|--------|-----------------|
| `:waiting` | `next: edit the file, then `hive <stage-verb> <slug>` again` |
| `:execute_waiting` | `next: edit/recover the reason-specific target, then `hive develop <slug>` again`. JSON uses `Hive::ExecuteWaitingAction`: dirty worktrees and branch-integrity failures target the worktree, no-change exits target `plan.md`, and `missing_research_output` is `kind=run` because editing `task.md` cannot satisfy the structured final-message gate. |
| `:complete` | `next: hive plan <slug>`, `hive develop <slug>`, or `hive archive <slug>` depending on current stage; JSON keeps path fields and uses the workflow command |
| `:execute_complete` | `next: hive open-pr <slug>`; JSON: `next_action.kind = "approve"` with `command = "hive approve <slug> --from 4-execute"` |
| `:review_complete` | `next: hive artifacts <slug>`; JSON: `next_action.kind = "approve"` with `command = "hive artifacts <slug> --from 6-review"` |
| `:execute_stale` | `next: edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run` |
| `:review_waiting` (escalations-only, no `reason` attr) | `next: edit reviews/escalations-NN.md or reviewer files, then `hive run <folder>` again`. JSON envelope: `target = task.folder`. |
| `:review_waiting reason=fix_guardrail` | `next: review every finding in reviews/fix-guardrail-NN.md; tick every `[ ]` to `[x]` to approve the guarded commits (partial ticks keep the pause), then re-run`. Approval is rejected if the file's checkbox count differs from `marker.matches` or the worktree HEAD differs from `marker.head`. JSON envelope: `target = <folder>/reviews/fix-guardrail-NN.md`, `instructions` cites the count and HEAD rejection rules. |
| `:review_error phase=reviewers reason=reviewer_partial_failure` | `next: recover review by clearing `REVIEW_ERROR` and rerunning`. JSON/status diagnostics include `<folder>/reviews/errors-NN.md`. |
| `:review_ci_stale` | `next: fix CI, edit reviews/ci-blocked.md, remove REVIEW_CI_STALE marker, re-run` |
| `:review_stale` | `next: if highest-pass reviewer files lack escalations-NN.md, remove REVIEW_STALE and re-run to retry that pass; otherwise edit/rename highest-pass review files, remove REVIEW_STALE, re-run` |
| `:manual_steering` | `next: manual steering active; automated run skipped`. JSON uses `next_action.kind="no_op"` and `reason="manual_steering"`. |
| `:review_error` | `next: investigate <reason>, then `hive markers clear FOLDER --name REVIEW_ERROR`, then re-run`. JSON: `next_action.kind = "review_error"` with `phase`, `reason`, and the full marker `attrs` surfaced so polling agents can branch without re-parsing the marker. Raises `Hive::TaskInErrorState` → exit 3 (`TASK_IN_ERROR`) after the JSON payload is emitted. |
| `:error` | raises `Hive::TaskInErrorState` → `bin/hive` rescues → exit 3 (`TASK_IN_ERROR`). JSON mode emits the full payload first, then raises — dual signal. **Reason-gated branch:** `reason=ensure_clean_on_exit_failed` emits `next_action.kind="edit"` with `target=worktree_path` (falls back to `task.folder`), `residue_paths` parsed from the comma string into an array, `instructions` carrying the `hive markers clear … --match-attr reason=ensure_clean_on_exit_failed` recovery one-liner, `markers_to_clear=["error"]`, and `rerun_with` set to the stage's friendly command. `Hive::TaskAction#suggested_next_action_payload` returns `{kind: "manual_fix", command: nil}` for this reason, mirroring the bot's manual-only routing (no auto-retry verb dispatched). Other `:error` reasons keep the generic NO_OP shape with `error: marker.attrs`. |

`next_stage_dir` increments `task.stage_index`; `9-done` has no `next:`.

## Stage routing

| Stage name | Runner | Page |
|-----------|--------|------|
| `inbox` | `Stages::Inbox` (inert) | [[stages/inbox]] |
| `brainstorm` | `Stages::Brainstorm` | [[stages/brainstorm]] |
| `plan` | `Stages::Plan` | [[stages/plan]] |
| `execute` | `Stages::Execute` | [[stages/execute]] |
| `open-pr` | `Stages::OpenPr` | [[stages/open-pr]] |
| `review` | `Stages::Review` | [[stages/review]] |
| `artifacts` | `Stages::Artifacts` | [[stages/artifacts]] |
| `finalize` | `Stages::Finalize` | [[stages/finalize]] |
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
- `test/integration/run_open_pr_test.rb`
- `test/integration/run_review_test.rb`
- `test/unit/stages/artifacts_test.rb`
- `test/integration/run_finalize_test.rb`
- `test/integration/run_done_test.rb`
- `test/integration/full_flow_test.rb` (chains all stages)

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/status]] · [[commands/approve]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/open-pr]] · [[stages/review]] · [[stages/artifacts]] · [[stages/finalize]] · [[stages/done]]
- [[modules/task]] · [[modules/lock]] · [[modules/markers]] · [[modules/git_ops]]

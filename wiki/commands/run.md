---
title: hive run
type: command
source: lib/hive/commands/run.rb
created: 2026-04-25
updated: 2026-05-14T00:00:00Z
tags: [command, dispatcher, stages, json, rebase]
---

**TLDR**: `hive run TARGET` is the lower-level dispatcher for a slug or task folder. It resolves `TARGET` into a `Hive::Task`, takes the per-task lock, attempts an auto-rebase pre-step against the project's default branch (fail-soft), picks the matching stage runner, executes it, commits any `.hive-state` changes via the per-project commit lock, and reports the resulting marker plus a workflow-oriented `next:` hint. Most humans should start with `hive status` and use `hive brainstorm|plan|develop|pr|archive <slug>`.

## Usage

```
hive run <slug> [--project NAME] [--stage STAGE] [--json]
hive run <project>/.hive-state/stages/<N>-<stage>/<slug> [--json]
```

`TARGET` is resolved by `Hive::TaskResolver`. Bare slugs search registered projects; `--project` scopes cross-project collisions; `--stage` scopes same-slug stage collisions. Folder paths remain exact and authoritative.

## Steps performed (`Commands::Run#call`)

1. Resolve `TARGET` via `Hive::TaskResolver` and load merged config via `Hive::Config.load(task.project_root)`.
2. Acquire the per-task lock via `Hive::Lock.with_task_lock` with payload `{slug:, stage:}`. Concurrent run → `ConcurrentRunError` (exit 75, `TEMPFAIL`, stderr `hive: another hive run is active`).
3. **Auto-rebase pre-step** (`Hive::Rebase.perform`): see "Auto-rebase pre-step" below.
4. `pick_runner(task)` returns one of `Hive::Stages::{Inbox,Brainstorm,Plan,Execute,Review,Pr,Done}.method(:run!)`. Unknown stage → `StageError`.
5. Call the runner: `runner.call(task, cfg)` → `{commit:, status:}`.
6. `commit_after`: if `result[:commit]`, take the per-project commit lock and run `GitOps#hive_commit(stage_name: "<N>-<stage>", slug:, action: result[:commit])`.
7. `report`: print the current marker, the state file path, and a stage-aware next step.

## Auto-rebase pre-step (`Hive::Rebase.perform`)

`hive run` checks whether the task's worktree branch is behind `origin/<default_branch>` and, if so, attempts a rebase before dispatching the stage runner. This prevents the failure mode where a long-running task's branch drifts behind main and reviewers in 5-review see "phantom deletions" of code that landed on main after the branch was created (originating incident: `i-want-to-be-able-260507-7682` at REVIEW_STALE pass=4).

**Trigger:** stages 4-execute, 5-review, 6-pr. Stages 2-brainstorm and 3-plan have no worktree (`task.worktree_path` is nil), so the trigger silently no-ops; 1-inbox doesn't enter `hive run`; 7-done is terminal.

**Pre-rebase guards (in order, before any fetch):**
1. `cfg.rebase.enabled == false` → `Result.disabled`.
2. `task.worktree_path` missing → `Result.skipped(:no_worktree)`.
3. `.git/rebase-merge/` or `.git/rebase-apply/` directory exists (pre-existing half-rebase from a prior aborted run) → `Result.skipped(:pre_existing_rebase)`. Emits a louder stderr warning naming the manual recovery: `cd <worktree_path> && git rebase --abort`.
4. Worktree dirty → `Result.skipped(:dirty_worktree)`.
5. Detached HEAD → `Result.skipped(:detached_head)`.

**Fetch:** `git fetch origin <default_branch>` runs with `GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=10"` set in the spawn environment, so credential/host-key prompts fail immediately rather than hanging. Failure → `Result.skipped(:fetch_failed)`.

**Conflict-resolution agent:** when `git rebase` halts with conflicts, `Hive::Rebase` dispatches the project's `cfg.execute.agent` profile via `Hive::Stages::Base.spawn_agent` with:
- `cwd: task.worktree_path` (the rebase state lives in the worktree)
- `add_dirs: []` (the agent is isolated from `task.folder` — it physically cannot touch `plan.md`/`worktree.yml`/`task.md`)
- `timeout_sec: cfg.rebase.conflict_resolution_timeout_sec` (default 2700)
- prompt rendered from `templates/rebase_conflict_resolution.md.erb` with the conflict files wrapped in a per-spawn `<user_supplied_<hex>>` nonce block (ADR-008/019)
- bounded by `Hive::Rebase::MAX_CONFLICT_RESOLUTIONS = 5` agent dispatches per rebase invocation (not configurable; projects with persistent high-conflict branches should investigate the drift, not raise the cap)

Before each dispatch, `Hive::Rebase` checks `staged_unmerged_files` against `Hive::ProtectedFiles::ORCHESTRATOR_OWNED` (`plan.md`, `worktree.yml`, `task.md`). If any protected file is in the conflict set, the rebase aborts without dispatching — the operator resolves manually.

**Fail-soft contract.** Any failure (agent non-zero exit, agent leaves conflict markers, agent runs `git rebase --continue` itself against the prompt directive, max attempts exceeded, fetch failure, protected-files conflict) triggers `git rebase --abort` followed by `git reset --hard ORIG_HEAD` (which removes agent-created untracked files that `--abort` doesn't clean). The worktree returns to its pre-rebase HEAD. The stage runner then proceeds against the (stale) base.

**Successful-rebase post-step (U8).** When the rebase completes cleanly, `Hive::Rebase` rewrites `worktree.yml`'s `execute_base_head` to the post-rebase HEAD SHA. Without this, 4-execute continuation passes would trip `EXECUTE_WAITING(reason=head_not_descendant)` because the stored pre-rebase SHA is no longer reachable in the rebased commit graph.

**Operator-visible signals.** Successful rebase emits `[hive] rebased N commits from origin onto <slug> branch [(K conflicts resolved by agent)]` to stderr. Any failure emits `[hive] rebase attempt failed (<reason>); continuing with stale base. Manual rebase recommended: cd <worktree_path> && git rebase origin/<default-branch>`.

**Per-project disable.** Set `rebase.enabled: false` in `<project>/.hive-state/config.yml` to opt out. The trigger becomes a silent no-op (`Result.disabled`).

**JSON envelope (`hive run --json`).** The `SuccessPayload` always includes a `rebase` block:

```json
{
  "rebase": {
    "attempted": true,
    "commits_behind": 3,
    "succeeded": true,
    "agent_resolutions": 1,
    "resolved_files": ["src/foo.rb"],
    "reason": null
  }
}
```

`reason` is `null` on success and a snake-case string (`disabled`, `no_worktree`, `dirty_worktree`, `pre_existing_rebase`, `detached_head`, `fetch_failed`, `agent_failed`, `markers_remaining`, `protected_files_in_conflict`, `max_attempts_exceeded`, `agent_called_continue_itself`, `rebase_failed`, `rebase_continue_failed`, `no_conflict_agent_configured`) otherwise.

## next: hints (by marker)

| Marker | `report` output |
|--------|-----------------|
| `:waiting` | `next: edit the file, then `hive <stage-verb> <slug>` again` |
| `:execute_waiting` | `next: edit/recover the reason-specific target, then `hive develop <slug>` again`. JSON uses `Hive::ExecuteWaitingAction`: dirty worktrees and branch-integrity failures target the worktree, no-change exits target `plan.md`, and `missing_research_output` is `kind=run` because editing `task.md` cannot satisfy the structured final-message gate. |
| `:complete` | `next: hive plan <slug>`, `hive develop <slug>`, or `hive archive <slug>` depending on current stage; JSON keeps path fields and uses the workflow command |
| `:execute_complete` | `next: hive develop <slug>` (advances to 5-review); JSON: `next_action.kind = "approve"` with `command = "hive approve <slug> --from 4-execute"` |
| `:review_complete` | `next: hive pr <slug>`; JSON: `next_action.kind = "approve"` with `command = "hive approve <slug> --from 5-review"` |
| `:execute_stale` | `next: edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run` |
| `:review_waiting` (escalations-only, no `reason` attr) | `next: edit reviews/escalations-NN.md or reviewer files, then `hive run <folder>` again`. JSON envelope: `target = task.folder`. |
| `:review_waiting reason=fix_guardrail` | `next: review every finding in reviews/fix-guardrail-NN.md; tick every `[ ]` to `[x]` to approve the guarded commits (partial ticks keep the pause), then re-run`. Approval is rejected if the file's checkbox count differs from `marker.matches` or the worktree HEAD differs from `marker.head`. JSON envelope: `target = <folder>/reviews/fix-guardrail-NN.md`, `instructions` cites the count and HEAD rejection rules. |
| `:review_waiting reason=reviewer_partial_failure` | `next: one or more reviewers failed for this pass; either re-run hoping for recovery or `hive markers clear <folder> --name REVIEW_WAITING` to accept the partial coverage, then re-run`. JSON envelope: `target = <folder>/reviews/errors-NN.md`. |
| `:review_ci_stale` | `next: fix CI, edit reviews/ci-blocked.md, remove REVIEW_CI_STALE marker, re-run` |
| `:review_stale` | `next: if highest-pass reviewer files lack escalations-NN.md, remove REVIEW_STALE and re-run to retry that pass; otherwise edit/rename highest-pass review files, remove REVIEW_STALE, re-run` |
| `:review_error` | `next: investigate <reason>, then `hive markers clear FOLDER --name REVIEW_ERROR`, then re-run`. JSON: `next_action.kind = "review_error"` with `phase`, `reason`, and the full marker `attrs` surfaced so polling agents can branch without re-parsing the marker. Raises `Hive::TaskInErrorState` → exit 3 (`TASK_IN_ERROR`) after the JSON payload is emitted. |
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
- `test/integration/run_review_test.rb`
- `test/integration/run_pr_test.rb`
- `test/integration/run_done_test.rb`
- `test/integration/full_flow_test.rb` (chains all stages)

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/status]] · [[commands/approve]]
- [[stages/inbox]] · [[stages/brainstorm]] · [[stages/plan]] · [[stages/execute]] · [[stages/review]] · [[stages/pr]] · [[stages/done]]
- [[modules/task]] · [[modules/lock]] · [[modules/markers]] · [[modules/git_ops]]

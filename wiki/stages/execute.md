---
title: 4-execute stage
type: stage
source: lib/hive/stages/execute.rb, templates/execute_prompt.md.erb
created: 2026-04-25
updated: 2026-05-13
tags: [stage, execute, worktree]
---

**TLDR**: Implementation-only since U9 (ADR-014). First entry creates a feature worktree at `<worktree_root>/<slug>`, records its baseline HEAD in `worktree.yml`, spawns the implementation agent, captures its final message into `task.md`, and finalises with `EXECUTE_COMPLETE` only when the worktree stays on the task branch, descends from the baseline, has a new commit, and is clean. Clean no-change exits pause as `EXECUTE_WAITING reason=no_worktree_changes` unless `plan.md` opts into `execution_mode: research` and the agent produced a structured final answer. The user `mv`s completed tasks to `6-review/` to enter the autonomous review loop. No review/iteration logic lives in 4-execute — that all moved to [[stages/review]].

## Setup

- **State file**: `task.md` with frontmatter `slug`, `started_at`. Initial body has `## Implementation` heading plus `<!-- AGENT_WORKING -->`.
- **Worktree pointer**: `worktree.yml` (created on init pass; gates re-entry).
- **Plan precondition**: `plan.md` must exist; otherwise stderr `"plan.md missing; this task did not pass through 3-plan"` and exit 1.

## Pre-flight state machine (`task_state`)

| Marker / State | Action |
|----------------|--------|
| `:execute_complete` | print `"already complete; mv this folder to 6-review/"`, return |
| `:execute_waiting` | re-run the implementation pass after the user reviews the captured `## Execute Output` and decides whether to revise the plan, add `execution_mode: research`, or retry |
| `:error` | warn with attrs; user investigates, clears marker |
| `worktree.yml` exists but path missing | warn `"worktree pointer present but worktree missing; recover with `git -C <root> worktree prune`, delete worktree.yml, then re-run"`, exit 1 |
| no `worktree.yml` | run **init pass** |
| `worktree.yml` exists, healthy | re-running on a complete task says "already complete; mv to 6-review/" |

`EXECUTE_WAITING` is still written by 4-execute for implementation-output pauses: `reason=no_worktree_changes` when the agent exits cleanly without a baseline-descendant commit, `reason=dirty_worktree` when it leaves uncommitted work behind, `reason=missing_research_output` when a research-mode plan has no structured final message, `reason=branch_mismatch` when the worktree is detached or on the wrong branch, and `reason=head_not_descendant` when HEAD no longer descends from the execute baseline. `EXECUTE_STALE` review-iteration state moved to `REVIEW_STALE` in 6-review.

## Init pass (`run_init_pass`)

1. `Worktree.new.create!(slug, default_branch: ...)` runs `git worktree add <root> -b <slug> <default>` (or attaches to an existing branch if it already exists).
2. `Worktree.validate_pointer_path` rejects worktrees outside the configured `worktree_root` prefix.
3. `Worktree#write_pointer!` writes `worktree.yml`, including `execute_base_head` for later baseline checks.
4. `write_initial_task_md`.
5. `spawn_implementation`.
6. Capture the agent's final stdout / stream-json result into `task.md` under `## Execute Output`.
7. SHA-256 protect pass on `plan.md` / `worktree.yml`.
8. Verify the worktree is on the expected task branch, descends from `execute_base_head`, is clean, and either has a new baseline-descendant commit or is an explicit `execution_mode: research` plan with a structured final agent message.
9. `EXECUTE_COMPLETE` or `EXECUTE_WAITING reason=...`.

Re-running with `worktree.yml` already present and a `:execute_complete` marker is a no-op announcing 6-review.

## Implementation sub-agent (`spawn_implementation`)

- **Prompt**: `templates/execute_prompt.md.erb` rendered with `project_name`, `worktree_path`, `task_folder`, `plan_text`. Plan is wrapped in `<user_supplied content_type="plan_md">`.
- **cwd**: feature worktree (so `claude` picks up the project's CLAUDE.md from there).
- **`--add-dir <task folder>`**: lets the agent read plan.md and append to `task.md` ("## Implementation" section).
- **Budgets**: `cfg["budget_usd"]["execute_implementation"]` (100), `cfg["timeout_sec"]["execute_implementation"]` (2700).
- **Log label**: `execute-impl`.
- **Final message capture**: `Hive::Agent` records the last `result`, `item.completed agent_message`, `assistant` stream-json message, or plain stdout tail. `Stages::Execute` writes it to `task.md` before the terminal marker so investigation work is not trapped only in raw logs. Only structured final messages count as research-mode output; plain stdout/stderr progress is preserved but does not complete research mode.
- Agent must commit each logical unit in the worktree and run lint/tests as it goes. May only edit `task.md` inside the task folder; must not touch `plan.md` or `worktree.yml` (SHA-256 protected, ADR-013).
- Normal success requires the worktree to remain on the branch from `worktree.yml`, HEAD to descend from `execute_base_head`, the worktree to be clean, and at least one new baseline-descendant commit. A clean no-commit exit pauses as `EXECUTE_WAITING reason=no_worktree_changes`; a dirty worktree pauses as `EXECUTE_WAITING reason=dirty_worktree`; detached/wrong-branch commits pause as `reason=branch_mismatch` or `reason=head_not_descendant`.
- Research-only execution is explicit: `plan.md` YAML frontmatter must include `execution_mode: research`. In that mode a clean no-commit exit can complete, but only if the final message was captured; otherwise it pauses as `EXECUTE_WAITING reason=missing_research_output`.

## Tests

- `test/unit/agent_test.rb` — captures final messages from stream-json result lines.
- `test/integration/run_execute_test.rb` — init pass produces `EXECUTE_COMPLETE`; no-change exits preserve `## Execute Output` and pause; research-mode no-change runs can complete with output; research-mode without output pauses; re-run announces 5-open-pr; tampering → `:error`; impl failure → `:error`; missing plan.md exits 1; no review files written.

## Backlinks

- [[stages/plan]] · [[stages/open-pr]] · [[stages/review]]
- [[modules/worktree]] · [[modules/agent]] · [[modules/markers]] · [[modules/git_ops]] · [[modules/findings]]
- [[commands/findings]] — list and toggle the `[x]` accepted-flag on findings this stage produces
- [[state-model]] · [[decisions]]

---
title: 4-execute stage
type: stage
source: lib/hive/stages/execute.rb, templates/execute_prompt.md.erb
created: 2026-04-25
updated: 2026-04-26
tags: [stage, execute, worktree]
---

**TLDR**: Implementation-only since U9 (ADR-014). First entry creates a feature worktree at `<worktree_root>/<slug>`, spawns the implementation agent, and finalises with `EXECUTE_COMPLETE`. The user `mv`s the task to `5-review/` to enter the autonomous review loop. No more review/iteration logic in 4-execute — that all moved to [[stages/review]].

## Setup

- **State file**: `task.md` with frontmatter `slug`, `started_at`. Initial body has `## Implementation` heading plus `<!-- AGENT_WORKING -->`.
- **Worktree pointer**: `worktree.yml` (created on init pass; gates re-entry).
- **Plan precondition**: `plan.md` must exist; otherwise stderr `"plan.md missing; this task did not pass through 3-plan"` and exit 1.

## Pre-flight state machine (`task_state`)

| Marker / State | Action |
|----------------|--------|
| `:execute_complete` | print `"already complete; mv this folder to 5-review/"`, return |
| `:error` | warn with attrs; user investigates, clears marker |
| `worktree.yml` exists but path missing | warn `"worktree pointer present but worktree missing; recover with `git -C <root> worktree prune`, delete worktree.yml, then re-run"`, exit 1 |
| no `worktree.yml` | run **init pass** |
| `worktree.yml` exists, healthy | re-running on a complete task says "already complete; mv to 5-review/" |

There is no longer an `:execute_waiting` or `:execute_stale` — those moved to `:review_waiting` / `:review_stale` in 5-review.

## Init pass (`run_init_pass`)

1. `Worktree.new.create!(slug, default_branch: ...)` runs `git worktree add <root> -b <slug> <default>` (or attaches to an existing branch if it already exists).
2. `Worktree.validate_pointer_path` rejects worktrees outside the configured `worktree_root` prefix.
3. `Worktree#write_pointer!` writes `worktree.yml`.
4. `write_initial_task_md`.
5. `spawn_implementation`.
6. SHA-256 protect pass on `plan.md` / `worktree.yml`.
7. `EXECUTE_COMPLETE`.

Re-running with `worktree.yml` already present and a `:execute_complete` marker is a no-op announcing 5-review.

## Implementation sub-agent (`spawn_implementation`)

- **Prompt**: `templates/execute_prompt.md.erb` rendered with `project_name`, `worktree_path`, `task_folder`, `plan_text`. Plan is wrapped in `<user_supplied content_type="plan_md">`.
- **cwd**: feature worktree (so `claude` picks up the project's CLAUDE.md from there).
- **`--add-dir <task folder>`**: lets the agent read plan.md and append to `task.md` ("## Implementation" section).
- **Budgets**: `cfg["budget_usd"]["execute_implementation"]` (100), `cfg["timeout_sec"]["execute_implementation"]` (2700).
- **Log label**: `execute-impl`.
- Agent must commit each logical unit in the worktree and run lint/tests as it goes. May only edit `task.md` inside the task folder; must not touch `plan.md` or `worktree.yml` (SHA-256 protected, ADR-013).

## Tests

- `test/integration/run_execute_test.rb` — init pass produces `EXECUTE_COMPLETE`; re-run announces 5-review; tampering → `:error`; impl failure → `:error`; missing plan.md exits 1; no review files written.

## Backlinks

- [[stages/plan]] · [[stages/review]] · [[stages/pr]]
- [[modules/worktree]] · [[modules/agent]] · [[modules/markers]] · [[modules/git_ops]] · [[modules/findings]]
- [[commands/findings]] — list and toggle the `[x]` accepted-flag on findings this stage produces
- [[state-model]] · [[decisions]]

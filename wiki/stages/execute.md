---
title: 4-execute stage
type: stage
source: lib/hive/stages/execute.rb, templates/execute_prompt.md.erb, templates/review_prompt.md.erb
created: 2026-04-25
updated: 2026-04-25
tags: [stage, execute, worktree, review]
---

**TLDR**: The most complex stage. First entry creates a feature worktree at `<worktree_root>/<slug>` and runs implementation + review pass 1. Subsequent runs read accepted findings (`[x]`) from `reviews/ce-review-NN.md`, apply them, run another review, and produce `reviews/ce-review-(NN+1).md`. Stops at `cfg["max_review_passes"]` (default 4) with `EXECUTE_STALE`, or on a clean review with `EXECUTE_COMPLETE`.

## Setup

- **State file**: `task.md` with frontmatter `slug`, `started_at`. Initial body has `## Implementation` and `## Review History` headings plus `<!-- AGENT_WORKING -->`. (Pass count is *not* tracked in frontmatter — see `current_pass_from_reviews`.)
- **Worktree pointer**: `worktree.yml` (created on init pass; gates iteration vs init).
- **Reviews directory**: `reviews/` (created at top of `run!`).
- **Plan precondition**: `plan.md` must exist; otherwise stderr `"plan.md missing; this task did not pass through 3-plan"` and exit 1.

## Pre-flight state machine (`task_state`)

| Marker / State | Action |
|----------------|--------|
| `:execute_complete` | print `"already complete; mv this folder to 5-pr/"`, return `{commit: nil, status: :execute_complete}` |
| `:execute_stale` | warn `"EXECUTE_STALE — edit reviews/, lower pass:, remove the marker, then re-run"`, return without re-spawning |
| `worktree.yml` exists but path missing | warn `"worktree pointer present but worktree missing; recover with `git -C <root> worktree prune`, delete worktree.yml, then re-run"`, exit 1 |
| no `worktree.yml` | run **init pass** |
| `worktree.yml` exists, healthy | run **iteration pass** |

## Init pass (`run_init_pass`)

1. `Worktree.new.create!(slug, default_branch: ...)` runs `git worktree add <root> -b <slug> <default>` (or attaches to an existing branch if it already exists).
2. `Worktree.validate_pointer_path` rejects worktrees outside the configured `worktree_root` prefix.
3. `Worktree#write_pointer!` writes `worktree.yml`.
4. `write_initial_task_md(pass: 1)`.
5. `spawn_implementation(pass: 1, accepted_findings: nil)`.
6. `run_review_pass(pass: 1)`.

## Iteration pass (`run_iteration_pass`)

1. Read pointer; re-validate prefix.
2. `previous_pass = read_pass_from_task_md(task)` (regex on `^pass:\s*(\d+)`).
3. If `previous_pass >= max_review_passes`, set `:execute_stale` marker with attrs `max_passes`, `pass`. Return `{commit: "stale_max_passes", status: :execute_stale}`.
4. `accepted = collect_accepted_findings(task, previous_pass)` — concatenate every `- [x] …` line from `reviews/ce-review-<previous_pass>.md`.
5. If accepted is empty → `:execute_complete pass=<previous_pass>`. Return `{commit: "complete_no_accepted"}`.
6. Otherwise `spawn_implementation(pass: previous_pass+1, accepted_findings: accepted)` then `run_review_pass(pass: previous_pass+1)`.

## Implementation sub-agent (`spawn_implementation`)

- **Prompt**: `templates/execute_prompt.md.erb` rendered with `project_name`, `worktree_path`, `task_folder`, `pass`, `plan_text`, `accepted_findings`. Plan and accepted findings are wrapped in `<user_supplied content_type="…">` blocks.
- **cwd**: feature worktree (so `claude` picks up the project's CLAUDE.md from there).
- **`--add-dir <task folder>`**: lets the agent read plan/accepted findings and append to `task.md` ("## Implementation" section).
- **Budgets**: `cfg["budget_usd"]["execute_implementation"]` (100), `cfg["timeout_sec"]["execute_implementation"]` (2700).
- **Log label**: `execute-impl-<NN>`.
- Agent must commit each logical unit in the worktree and run lint/tests as it goes. May only edit `task.md` inside the task folder; must not touch `plan.md` or `worktree.yml`.

## Reviewer sub-agent (`run_review_pass`)

- **Prompt**: `templates/review_prompt.md.erb` rendered with `worktree_path`, `task_folder`, `default_branch`, `pass`. Reviewer runs `/compound-engineering:ce-review` on `git diff <default>..HEAD` in the worktree.
- Output goes to `reviews/ce-review-<NN>.md` with `## High` / `## Medium` / `## Nit` GFM checkbox sections — every finding rendered as `- [ ]` (the user later ticks `[x]` to accept).
- After spawn, `protected_files = %w[plan.md worktree.yml]` are SHA-256 compared pre/post; on tampering, set `:error reason=reviewer_tampered files=…` and return `{commit: "review_tampered", status: :error}`.
- **Budgets**: `cfg["budget_usd"]["execute_review"]` (50), `cfg["timeout_sec"]["execute_review"]` (600). Log label: `execute-review-<NN>`.

## Finalisation (`finalize_review_state`)

- If `reviews/ce-review-<NN>.md` exists and has `count_findings > 0`: set `:execute_waiting findings_count=N pass=NN`, return `{commit: "review_pass_<NN>_waiting", status: :execute_waiting}`.
- Else: set `:execute_complete pass=NN`, return `{commit: "review_pass_<NN>_complete", status: :execute_complete}`.

`count_findings` regex: `/^\s*-\s+\[[ x]\]\s+/`. Counts both checked and unchecked rows — i.e., any review entry counts as a finding to triage.

## EXECUTE_STALE recovery

When pass count hits `max_review_passes`:

1. Edit `reviews/ce-review-<last>.md` manually — consolidate or trim findings.
2. Decrement `pass:` in `task.md` frontmatter.
3. Remove the `<!-- EXECUTE_STALE … -->` marker.
4. `hive run` again — runner re-enters iteration pass.

## Tests

- `test/integration/run_execute_test.rb` covers init pass, iteration pass, missing-plan rejection, stale-marker handling, worktree-missing recovery, and reviewer-tamper detection.

## Backlinks

- [[stages/plan]] · [[stages/pr]]
- [[modules/worktree]] · [[modules/agent]] · [[modules/markers]] · [[modules/git_ops]]
- [[state-model]]

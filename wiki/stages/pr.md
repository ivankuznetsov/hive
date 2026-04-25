---
title: 6-pr stage
type: stage
source: lib/hive/stages/pr.rb, templates/pr_prompt.md.erb, templates/pr_body.md.erb
created: 2026-04-25
updated: 2026-04-25
tags: [stage, pr, github]
---

**TLDR**: Pushes the feature branch to `origin`, looks up an existing PR (idempotent), and if none exists, runs an agent to author title + body and call `gh pr create`. Agent writes `pr.md` with frontmatter `pr_url`/`pr_number` and a `<!-- COMPLETE pr_url=… -->` marker.

## Preconditions

1. `worktree.yml` must exist in the task folder; otherwise stderr `"no worktree pointer; this task did not pass through 4-execute"` and exit 1.
2. The pointer's `path` directory must exist; otherwise stderr `"worktree pointer at <path> no longer exists; recreate or move task back to 4-execute"` and exit 1.
3. `gh auth status` must succeed; otherwise stderr the `gh` error and exit 1 (`ensure_gh_authenticated!`).

## Steps performed (`Stages::Pr.run!`)

1. `git -C <worktree> push -u origin <branch>` (`push_branch!`). Branch defaults to the slug if pointer doesn't carry one. Push failure → exit 1.
2. `gh pr list --head <branch> --state open --json url,number` → if non-empty, write `pr.md` with `idempotent=true` attribute on the COMPLETE marker and return `{commit: "pr_already_open", status: :complete}`. No agent spawn in this case.
3. Otherwise, render `templates/pr_prompt.md.erb` with `worktree_path`, `task_folder`, `slug`, `plan_text`, `reviews_summary` (concatenation of every `reviews/*.md` with per-file headers). Plan and reviews are wrapped in `<user_supplied content_type="…">` blocks.
4. Spawn agent at `cwd = worktree`, `--add-dir <task folder>`. Log label `pr`. Budgets: `cfg["budget_usd"]["pr"]` (10), `cfg["timeout_sec"]["pr"]` (300).
5. Agent runs `gh pr create --title "<title>" --body-file <path> --head <slug>` and writes `pr.md`. The body template (`templates/pr_body.md.erb`) is `## Summary` + `## Test plan` + `## Linked task <task_folder>`.
6. `pr.md` ends with `<!-- COMPLETE pr_url=<url> -->`.

## Marker → commit action

- `:complete` → `pr_opened` (or `pr_already_open` for the idempotent path).
- Otherwise → `marker.name.to_s`.

## Constraints (per prompt template)

- Do not push the branch (already done by the runner).
- Do not include `.env`, secrets, tokens, or any file outside the task folder/worktree in the PR body.
- The trailing marker in `pr.md` must be exactly `<!-- COMPLETE pr_url=... -->`.

## Tests

- `test/integration/run_pr_test.rb` covers: existing-PR idempotent path, push failure exit, and the agent path with the `fake-gh` fixture returning a dummy URL.

## Backlinks

- [[stages/execute]] · [[stages/done]]
- [[modules/worktree]] · [[modules/agent]]
- [[state-model]]

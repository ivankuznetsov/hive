---
title: 7-finalize stage
type: stage
source: lib/hive/stages/finalize.rb, templates/finalize_prompt.md.erb, templates/finalize_summary.md.erb
created: 2026-05-13
updated: 2026-05-13
tags: [stage, finalize, pr, github]
---

**TLDR**: Wraps up an already-open draft PR after 6-review completes. It verifies the worktree is clean and pushed, refreshes the PR body, writes `summary.md`, and flips the PR from draft to ready-for-review.

## Preconditions

1. `worktree.yml` must exist and point at a live worktree.
2. `pr.md` must already exist with `pr_url` frontmatter from 5-open-pr.
3. `gh auth status` must succeed.
4. The feature worktree must be clean; otherwise the stage writes `<!-- ERROR reason=dirty_worktree -->`.
5. The branch must be pushed to its upstream. The runner attempts one push before writing `<!-- ERROR reason=unpushed_commits -->`.

## Steps performed (`Stages::Finalize.run!`)

1. Read `pr_url` from `pr.md`.
2. Verify git status and upstream state.
3. Render `templates/finalize_prompt.md.erb` with plan, review files, task folder, worktree path, and PR URL.
4. Spawn the finalize agent in the worktree. The prompt instructs it to update the PR body, write `summary.md`, append `<!-- COMPLETE pr_url=... is_draft=false -->` to `pr.md`, and call `gh pr ready` last.
5. Secret-scan `pr.md` and the PR body. On a hit, best-effort reverts to draft with `gh pr ready --undo` and writes `ERROR reason=secret_in_pr_body`.
6. Ensure `summary.md` exists, rendering `templates/finalize_summary.md.erb` as a fallback.

## Marker → commit action

- `:complete` → `pr_finalized`.
- Dirty or unpushed state writes an `ERROR` marker and commits the corresponding error state.

## Backlinks

- [[stages/open-pr]] · [[stages/review]] · [[stages/done]]
- [[state-model]] · [[commands/stage_action]]

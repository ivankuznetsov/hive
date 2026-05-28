---
title: 8-finalize stage
type: stage
source: lib/hive/stages/finalize.rb, templates/finalize_prompt.md.erb, templates/finalize_summary.md.erb
created: 2026-05-13
updated: 2026-05-28
tags: [stage, finalize, pr, github, clean-exit]
---

**TLDR**: Wraps up an already-open draft PR after 7-artifacts completes. On entry it now self-heals worktree residue via the `CleanExit` backstop (auto-commits in-scope edits, surfaces scope violations as `:error reason=ensure_clean_on_exit_failed`), then refreshes the PR body, writes `summary.md`, and flips the PR from draft to ready-for-review.

## Preconditions

1. `worktree.yml` must exist and point at a live worktree.
2. `pr.md` must already exist with `pr_url` frontmatter from 5-open-pr; missing PR metadata records `ERROR reason=missing_pr_md` or `ERROR reason=missing_pr_url`.
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
- Status only treats an `8-finalize` `:complete` marker as archive-ready when it carries `is_draft=false` and a `pr_url` matching `pr.md` frontmatter. A carried-over `5-open-pr` marker with `is_draft=true` remains ready to run finalize, not ready to archive.
- Missing `pr.md` / missing `pr_url`, dirty worktree, or unpushed state writes an `ERROR` marker and commits the corresponding error state.

## Backlinks

- [[stages/open-pr]] · [[stages/review]] · [[stages/done]]
- [[state-model]] · [[commands/stage_action]]

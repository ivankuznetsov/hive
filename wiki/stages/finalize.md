---
title: 8-finalize stage
type: stage
source: lib/hive/stages/finalize.rb, templates/finalize_prompt.md.erb, templates/finalize_summary.md.erb
created: 2026-05-13
updated: 2026-07-18
tags: [stage, finalize, pr, github, clean-exit]
---

**TLDR**: Wraps up an already-open draft PR after 7-artifacts completes. If GitHub already reports the PR as merged, finalize short-circuits to `COMPLETE merged=true` without refreshing the body or touching the stale local branch. Otherwise it self-heals worktree residue via the `CleanExit` backstop (auto-commits in-scope edits, surfaces scope violations as `:error reason=ensure_clean_on_exit_failed`), resyncs stale patch-identical rebase duplicates to upstream without discarding real local work, refreshes the PR body, writes `summary.md`, and flips the PR from draft to ready-for-review.

## Preconditions

1. `worktree.yml` must exist and point at a live worktree.
2. `pr.md` must already exist with `pr_url` frontmatter from 5-open-pr; missing PR metadata records `ERROR reason=missing_pr_md` or `ERROR reason=missing_pr_url`.
3. Unless the PR is already `MERGED`, `gh auth status` must succeed. A `Hive::Gh.pr_state` lookup error does not skip finalize; it falls through to the normal auth/status/body-refresh path.
4. The feature worktree must be clean on exit. The new clean-exit invariant (`Hive::Stages::CleanExit`, gated on `stages.ensure_clean_on_exit`) runs as both an entry backstop (Finalize self-heals dirty residue when 6-review left untracked changes behind) and a `with_stage_events` exit hook on every WORKTREE_OWNING stage. In-scope residue (review.fix.auto_commit.scope_check allowlist) is auto-committed; out-of-scope residue or git failure overwrites the marker to `<!-- ERROR reason=ensure_clean_on_exit_failed residue_paths=... -->`. Legacy `<!-- ERROR reason=dirty_worktree -->` markers continue to write when entry preflight fails before CleanExit runs.
5. The branch must be pushed to its upstream. The runner attempts one push before writing `<!-- ERROR reason=unpushed_commits -->`. If that push fails because the local worktree is the stale side of a remote auto-rebase, `resync_stale_rebase!` runs `git cherry <branch>@{u} HEAD`; only when every local commit is patch-identical upstream (`-` lines, no `+` lines) does it `git reset --hard <branch>@{u}` and continue. A genuinely unpushed local change still writes `ERROR reason=unpushed_commits` and is not discarded. The daemon healer treats that specific finalize marker as retryable when no task lock is live: it clears the marker with a bounded retry budget, matches the observed `marker_id` when present, and seeds the pre-clear mtime as the dispatch baseline, so finalize can rerun the clean-exit backstop and push path after the normal debounce instead of waiting for a human edit. The same bounded retry path handles finalize `ERROR reason=tmux_session_terminated` and `ERROR reason=agent_orphaned` because those indicate a lost agent session rather than a repository-state failure. Persistent non-ff/auth/remote failures and `ERROR reason=git_status_failed` remain red after the budget is exhausted or while they need operator inspection, with a one-shot `marker_heal_exhausted` daemon log event on budget exhaustion. Once GitHub reports the PR as `MERGED`, however, the daemon may archive stale `git_status_failed` or `claude_launch_failed` finalize errors through the internal `hive archive --recover-merged-error-reason` path; that path re-checks the current marker reason and PR state before moving the task to `9-done`.

The worktree precondition is enforced by `Hive::Stages::Base.worktree_pointer_or_exit`, shared with [[stages/open-pr]] so both stages preserve the same missing-pointer and missing-directory UX.

## Steps performed (`Stages::Finalize.run!`)

1. Read `pr_url` from `pr.md`.
2. Ask `Hive::Gh.pr_state(pr_url)` whether the PR is already `MERGED`. If yes, append `<!-- COMPLETE pr_url=... is_draft=false merged=true -->` and return `finalize_already_merged` without spawning the finalize agent, running `gh pr ready`, or requiring a healthy local branch.
3. Verify git status and upstream state.
4. Render `templates/finalize_prompt.md.erb` with plan, review files, task folder, worktree path, and PR URL.
5. Spawn the finalize agent in the worktree. The prompt instructs it to update the PR body, write `summary.md`, append `<!-- COMPLETE pr_url=... is_draft=false -->` to `pr.md`, and call `gh pr ready` last.
6. Secret-scan `pr.md` and the PR body. On a hit, best-effort reverts to draft with `gh pr ready --undo` and writes `ERROR reason=secret_in_pr_body`.
7. Ensure `summary.md` exists, rendering `templates/finalize_summary.md.erb` as a fallback.

## Marker → commit action

- Agent-written `:complete` → `pr_finalized`.
- Already-merged short-circuit `:complete merged=true` → `finalize_already_merged`; no `summary.md` is expected because the PR is already terminal on GitHub.
- Status only treats an `8-finalize` `:complete` marker as archive-ready when it carries `is_draft=false` and a `pr_url` matching `pr.md` frontmatter. A carried-over `5-open-pr` marker with `is_draft=true` remains ready to run finalize, not ready to archive.
- Missing `pr.md` / missing `pr_url`, dirty worktree, or genuinely unpushed state writes an `ERROR` marker and commits the corresponding error state. Patch-identical stale rebase duplicates are fast-forwarded to the upstream instead of becoming terminal `unpushed_commits`.

## Backlinks

- [[stages/open-pr]] · [[stages/review]] · [[stages/done]]
- [[state-model]] · [[commands/stage_action]]

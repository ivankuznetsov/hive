---
title: 8-finalize stage
type: stage
source: lib/hive/stages/finalize.rb, lib/hive/task_closure.rb, templates/finalize_prompt.md.erb, templates/finalize_summary.md.erb
created: 2026-05-13
updated: 2026-07-25
tags: [stage, finalize, pr, github, clean-exit, closure]
---

**TLDR**: Wraps up an already-open draft PR after 7-artifacts completes. If GitHub already reports the PR as merged, finalize short-circuits to `COMPLETE merged=true` without refreshing the body or touching the stale local branch. Otherwise it self-heals worktree residue via the `CleanExit` backstop (auto-commits in-scope edits, surfaces scope violations as `:error reason=ensure_clean_on_exit_failed`), refreshes the PR body, writes `summary.md`, and flips the PR from draft to ready-for-review. Auto-rebase now safely publishes rewritten PR branches at the rebase boundary; finalize's patch-identical force path remains a recovery backstop for older or externally produced stale histories.

## Preconditions

1. `worktree.yml` must exist and point at a live worktree.
2. `pr.md` must already exist with `pr_url` frontmatter from 5-open-pr; missing PR metadata records `ERROR reason=missing_pr_md` or `ERROR reason=missing_pr_url`.
3. Unless the PR is already `MERGED`, `gh auth status` must succeed. A `Hive::Gh.pr_state` lookup error does not skip finalize; it falls through to the normal auth/status/body-refresh path.
4. The feature worktree must be clean on exit. The new clean-exit invariant (`Hive::Stages::CleanExit`, gated on `stages.ensure_clean_on_exit`) runs as both an entry backstop (Finalize self-heals dirty residue when 6-review left untracked changes behind) and a `with_stage_events` exit hook on every WORKTREE_OWNING stage. In-scope residue (review.fix.auto_commit.scope_check allowlist) is auto-committed; out-of-scope residue or git failure overwrites the marker to `<!-- ERROR reason=ensure_clean_on_exit_failed residue_paths=... -->`. Legacy `<!-- ERROR reason=dirty_worktree -->` markers continue to write when entry preflight fails before CleanExit runs.
5. The branch must be pushed to its upstream. Auto-rebase publishes a successfully rewritten PR branch immediately with an exact pre-rebase remote-OID lease, so later stage commits normally remain fast-forward pushable. Finalize still attempts one push before writing `<!-- ERROR reason=unpushed_commits -->`. If that push fails because the local worktree is the stale side of older or externally produced remote auto-rebase history, `resync_stale_rebase!` runs `git cherry <branch>@{u} HEAD`; only when every local commit is patch-identical upstream (`-` lines, no `+` lines) does it `git reset --hard <branch>@{u}` and continue. A genuinely unpushed local change still writes `ERROR reason=unpushed_commits` and is not discarded. Like every finalize error, it remains eligible for the unbounded shared-cooldown retry when no task lock is live and current safety evidence passes. The scheduler submits the observation; `RecoveryCoordinator` owns the marker-id guard and workflow-derived finalize request, so re-entry still runs the ordinary clean-exit, auth, secret, and push checks. Independently, the durable task-bound merge reconciler observes PR-bearing tasks in stages 5–8. Once it verifies the exact task PR as merged, checkpoints required architecture intake, and revalidates generation/ownership/worktree safety, it writes a daemon-owned closure receipt and uses the centralized transition to `9-done`; no special finalize error allowlist or archive bypass remains.

The worktree precondition is enforced by `Hive::Stages::Base.worktree_pointer_or_exit`, shared with [[stages/open-pr]] so both stages preserve the same missing-pointer and missing-directory UX.

Tasks delivered by a later or replacement PR do not fabricate an empty PR or
weaken this stage's preconditions. An authenticated operator instead uses the
evidence-bound closure flow documented in [[commands/stage_action]]. It
verifies immutable GitHub evidence, writes a task-bound `closure.json`, and
invokes the centralized archive transition through a receipt-only guard.
Ordinary `hive archive <slug>` still requires a valid completed
`8-finalize` task.

The daemon uses a narrower internal authority for a task's own
same-repository PR: `TaskClosure.reconcile_remote_merge!` writes
`authority=remote_merge`, `channel=daemon`, and cannot take over an
operator-owned closure. It does not authorize cross-repository or semantic
supersession. The final closure re-read must match the reconciler's exact PR
head and merge OIDs. Remote facts and architecture acceptance are checkpointed in
the project-local reconciliation ledger before archive so restart replay does
not repeat accepted work.

## Steps performed (`Stages::Finalize.run!`)

1. Read `pr_url` from `pr.md`.
2. Secret-scan the local source and current remote PR body before auth, agent,
   ready-state, or branch mutation. Fetch failure writes
   `ERROR reason=secret_scan_fetch_failed`; a hit best-effort redacts the
   remote body and writes `ERROR reason=secret_in_pr_body`.
3. Ask `Hive::Gh.pr_state(pr_url)` whether the PR is already `MERGED`. If yes, append `<!-- COMPLETE pr_url=... is_draft=false merged=true -->` and return `finalize_already_merged` without spawning the finalize agent, running `gh pr ready`, or requiring a healthy local branch.
4. Verify git status and upstream state.
5. Render `templates/finalize_prompt.md.erb` with plan, review files, task folder, worktree path, and PR URL.
6. Spawn the finalize agent in the worktree. Controller-owned task files are
   captured before spawn; any changed bytes are restored atomically before
   `ERROR reason=finalize_tampered restored=true|false` is written. The prompt
   instructs the agent to update the PR body, write `summary.md`, append
   `<!-- COMPLETE pr_url=... is_draft=false -->` to `pr.md`, and call
   `gh pr ready` last.
7. Secret-scan `pr.md` and the PR body again after the authored update. On a
   hit, best-effort reverts to draft with `gh pr ready --undo` and writes
   `ERROR reason=secret_in_pr_body`.
8. Ensure `summary.md` exists, rendering `templates/finalize_summary.md.erb` as a fallback.

## Marker → commit action

- Agent-written `:complete` → `pr_finalized`.
- Already-merged short-circuit `:complete merged=true` → `finalize_already_merged`; no `summary.md` is expected because the PR is already terminal on GitHub.
- Status only treats an `8-finalize` `:complete` marker as archive-ready when it carries `is_draft=false` and a `pr_url` matching `pr.md` frontmatter. A carried-over `5-open-pr` marker with `is_draft=true` remains ready to run finalize, not ready to archive.
- Missing `pr.md` / missing `pr_url`, dirty worktree, or genuinely unpushed state writes an `ERROR` marker and commits the corresponding error state. Patch-identical stale rebase duplicates are fast-forwarded to the upstream instead of becoming terminal `unpushed_commits`.

## Backlinks

- [[stages/open-pr]] · [[stages/review]] · [[stages/done]]
- [[state-model]] · [[commands/stage_action]]

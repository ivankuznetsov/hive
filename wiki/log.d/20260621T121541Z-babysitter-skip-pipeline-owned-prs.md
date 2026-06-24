## [2026-06-21T12:15:41Z] babysitter — skip PRs owned by an active pipeline task

**Action:** Closed the babysitter-vs-pipeline rebase race that left patrol
finalize tasks looping on `:error reason=unpushed_commits`.

Root cause: a patrol PR is opened as a draft (so the babysitter's `isDraft`
skip protects it through review), but `8-finalize` runs `gh pr ready` to
un-draft it before merge (the merge is external — `PrMergeWatcher` only watches
for `MERGED`). Once ready, the babysitter's `select_prs` — which filtered only
on `isDraft`, labels, and inflight — treated it as a normal open PR and rebased
+ force-pushed its branch onto the advanced `main`, while the patrol task's own
worktree stayed pinned to its old base. Finalize's push gate then saw genuine
bidirectional divergence (remote has a main commit not in HEAD; HEAD has local
fix commits not on the remote), refused to force-push, and looped on
`unpushed_commits`.

Fix: `Hive::Babysitter::ProjectTick` now consults hive-state (the `hive/state`
branch — the git source of truth for ownership) instead of relying on the
GitHub draft flag. `pipeline_owned_branches` collects the `worktree.yml`
`branch` of every task in a non-terminal stage (`Hive::Stages::DIRS` filtered by
`Hive::Workflows.verb_advancing_from`, so the done stage is excluded and no
stage literal is hardcoded — respects the stage-literal guard). `select_prs`
skips any PR whose `headRefName` is in that set, ahead of the draft check,
emitting the new `Events` outcome `pipeline_owned`. A missing/malformed
`worktree.yml` is skipped so one bad task never aborts the scan, and a
done-stage task no longer shields its branch.

Tests: `test/unit/babysitter/project_tick_test.rb` — owned-active-task skip
(non-draft, with a pre-execute task that contributes no branch), done-stage task
not protected, and malformed pointer doesn't crash the scan. Full babysitter
suite (97) + rubocop green; new lib lines fully covered.

**Refreshed pages:**
- [[modules/babysitter]]

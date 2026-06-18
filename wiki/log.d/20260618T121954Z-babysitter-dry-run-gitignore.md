---
date: 2026-06-18
slug: babysitter-dry-run-gitignore
pages: [commands/babysit, stages/review]
---

Fixed a recurring `6-review` failure on patrol command-review tasks that
exercise the babysitter stubs (`patrol-command-bin-hive-babysitter-stub-gh-*`).
`Hive::Babysitter::DryRunEnv#with_env` points `HIVE_BABYSITTER_DRY_RUN_LOG` at
`<worktree>/.babysitter-dry-run-skipped.log` and `prepare_overlay` writes a
`<worktree>/.hive-babysitter-dry-run-bin/` PATH overlay of git/gh stub
wrappers. Neither artifact was gitignored, so after the dry-run the review
worktree carried untracked residue; the stage-exit clean-exit auto-commit
scope-check rejected `.babysitter-dry-run-skipped.log` as outside
`review.fix.auto_commit.scope_check.allowed_paths` and the task died with
`ERROR reason=ensure_clean_on_exit_failed` (observed on task id 1367).

Added both paths to `.gitignore` so git (and therefore clean-exit's residue
detection) ignores them — they are ephemeral run scaffolding that must never be
committed. Verified with `git check-ignore` and a clean `git status`. No
behavior change to the dry-run itself. Separate from the 6-review
error-surfacing / triage-retry work in PR #512.

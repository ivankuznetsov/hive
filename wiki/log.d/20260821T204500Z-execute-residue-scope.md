# Preserve complete execute residue outside review-fix paths

**Action:** Made `hive worktree commit-residue --complete-execute` identify its
CleanExit snapshot as `execute_residue_recovery`. That explicit, execute-only
boundary now preserves the whole already-produced implementation even when a
planned file is outside `review.fix.auto_commit.scope_check.allowed_paths`.

The ordinary residue commit and normal stage-exit paths keep the filename
allowlist. Complete-execute recovery still requires the exact dirty execute
marker and owned worktree, and it retains signing, staged-symlink,
secret-content, branch, ancestry, new-commit, and cleanliness checks before
writing `EXECUTE_COMPLETE`.

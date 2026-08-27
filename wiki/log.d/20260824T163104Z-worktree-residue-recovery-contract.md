# Unify worktree residue recovery across Review and CLI

## [2026-08-24T16:31:04Z] worktree — preserve typed pre-fix residue

- Fixed `hive worktree` ownership validation to resolve the expected root from
  the task's project repository. A configured root is no longer passed back
  through the project-root resolver and suffixed as `.worktrees.worktrees`.
- Centralized CleanExit recovery-marker attributes, including typed
  `failure_kind` and exact path recovery, and reused them from both the
  stage-exit and Finalize-entry producers. Large path sets use a digest-bound
  task-local sidecar so the marker remains inside its bounded scan window;
  secret-shaped filenames also use that owner-private sidecar while marker
  diagnostics and Git failure detail stay redacted before byte bounding.
  Recovery accepts literal
  POSIX backslashes and whitespace filename bytes through Git's literal path
  mode without weakening staged auto-commit policy validation.
- Changed Review's pre-fix snapshot so safety, scope, configuration, and Git
  failures on known dirty residue write canonical `ERROR
  reason=ensure_clean_on_exit_failed origin=review_pre_fix` state and stop
  before launching a fix agent. A Git-status failure before dirt is known
  remains the existing retryable Review error.
- Added regressions for a real configured root, inline and sidecar path
  recovery, signing-policy failures, redacted filenames, and the oversized
  visual-baseline incident shape. The latter proves generated PNG
  residue remains discardable while meaningful source residue stays dirty and
  unstaged for native recovery.

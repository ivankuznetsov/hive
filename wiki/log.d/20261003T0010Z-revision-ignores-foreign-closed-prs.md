# 2026-10-03 — Revision pushes also ignore foreign closed PRs

- #1510 let first publication ignore a closed, unowned PR on the task
  branch, but `revision_pull_request` (pushing a reworked head to the
  existing PR) still counted every PR on the branch. hivedev C2's branch
  carries the closed #7 and #8, so each push of its outcome-evidence rework to
  #9 failed with `revision_identity_conflict`.
- Both paths now use `branch_candidates`, which drops CLOSED records that the
  path's ownership predicate (`exact_owned?` or `revision_owned?`) does not
  claim.

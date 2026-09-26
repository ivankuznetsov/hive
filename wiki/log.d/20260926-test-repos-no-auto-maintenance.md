# 2026-09-26 — Test fixture repos disable Git auto-maintenance

- Git can fork a detached `git maintenance run --auto` after a fixture commit.
  It wrote `.git/objects/maintenance.lock` while the test's tmpdir was being
  removed, so cleanup raised `Errno::ENOENT` (seen in
  `PlanReviewCeDocReviewAdapterTest`, which blocked a task's CI after three
  fix attempts).
- `with_tmp_git_repo` and the plan-review adapter fixture now set
  `maintenance.auto=false` and `gc.auto=0` in the fixture repo's local config
  via `disable_git_auto_maintenance!`.

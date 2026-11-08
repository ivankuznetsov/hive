# 2026-09-25 — Planning and plan review inspect the execution base

- `PlanReview::DisposableWorktree` now checks out the revision execution will
  start from (`DisposableWorktree.execution_base`: `origin/<default>` after a
  fetch, else the local default branch, the same rule as
  `Worktree#create!`) instead of the project checkout's `HEAD`. Plan-review
  agents and planner revisions therefore review current code.
- The plan stage gives the planner a disposable detached checkout of that base,
  adds it to the planner's directories, and names it in the prompt as the
  source to inspect.
- Observed failure: the project checkout was on an unrelated branch 83 commits
  behind `origin/main` with local edits. A plan was written and reviewed
  against it, then execution (based on `origin/main`) refused it because the
  plan required commands `main` had deliberately removed.

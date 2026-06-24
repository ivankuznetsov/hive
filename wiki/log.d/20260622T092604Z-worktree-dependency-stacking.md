---
date: 2026-06-22
slug: worktree-dependency-stacking
pages: [modules/worktree, modules/task_dependencies, testing, gaps]
---

Fixed and documented dependency-stacked worktree creation when a dependent task
already has an empty placeholder branch. `Hive::Worktree#create!` now preserves
existing branches with real commits, but deletes a zero-commit placeholder
measured against the default branch when a non-empty stacked override is
present, then recreates the task branch through the normal base-resolution path.
`freshest_override_base` now resolves stacked bases as `origin/<prereq>` then
local `refs/heads/<prereq>` before falling back to the default branch.

Refreshed [[modules/worktree]] and [[modules/task_dependencies]] for the new
origin/local/default base order and placeholder handling, and refreshed
[[testing]] for the focused worktree regressions. Updated [[gaps]] with the
branch-creator investigation: no separate in-`lib/` normal task-branch
pre-creator was found; the leading cause is a stale placeholder branch left by
a prior collapsed execute attempt.

Verification on this branch:

- `bundle exec ruby -Itest test/unit/worktree_test.rb`
- `bundle exec rake test`
- `bundle exec rake coverage`
- `bundle exec rubocop lib/hive/worktree.rb test/unit/worktree_test.rb`

---
date: 2026-06-22
slug: worktree-placeholder-origin-measure
pages: [modules/worktree, modules/task_dependencies, testing]
---

Review-fix pass on the dependency-stacking branch. The empty-placeholder check
(`empty_placeholder?`) previously measured `git rev-list --count
<local-default>..<branch>`, which silently defeated the re-point fix: a
placeholder created by a prior run from `origin/<default>` (via
`freshest_base`) sits ahead of a lagging local default, so the local-ref
measurement counted the origin-ahead commits, misread the empty placeholder as
carrying real work, and collapsed stacking onto the stale base. The check now
measures against `origin/<default>` when its tracking ref exists, falling back
to local `<default>` only when absent. A rev-list error is now fail-closed
*and* warned (it used to fold into "not a placeholder" silently), and
`override_local_or_default` now carries the distinguishing reason (no origin /
fetch failed / ref missing) into its warning instead of always claiming
`origin/<branch> unavailable`, with the shared default-fallback tail moved into
the helper. `delete_local_branch!` appends a checked-out-elsewhere remediation
hint.

New regressions in [[testing]]: origin-ahead-of-local placeholder re-point
(locks in the measurement-basis fix), fail-closed preservation when the
emptiness check errors, and the `local_branch_ref_exists?` blank-name guard;
the delete-failure test now also asserts git's underlying reason survives in
the message. Refreshed [[modules/worktree]] and [[modules/task_dependencies]]
for the origin-first measurement basis (framed as a heuristic distinct from the
origin→local→default recreate base).

Verification on this branch:

- `bundle exec ruby -Itest test/unit/worktree_test.rb`
- `bundle exec rubocop lib/hive/worktree.rb test/unit/worktree_test.rb`

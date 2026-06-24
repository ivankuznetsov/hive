---
date: 2026-06-22
slug: worktree-placeholder-either-ref
pages: [modules/worktree, testing]
---

Review-fix pass 02 on the dependency-stacking branch, two findings.

`empty_placeholder?` no longer picks a single base ref (origin-when-present,
else local). Pass 01's origin-first basis fixed the origin-ahead-of-local case
but left the inverse open: a placeholder created by `freshest_base`'s
fetch-failure fallback from a *local* default that runs ahead of a *stale*
origin sits ahead of `origin/<default>`, so the origin-only measurement counted
the local-ahead commit and misread the empty placeholder as carrying work —
collapsing stacking again. The check now measures against **both**
`origin/<default>` (when its tracking ref exists) and local `<default>`, and
treats the branch as empty when it carries no unique commits beyond **either**
ref (brainstorm A1: "no unique commits vs EITHER"). The real-work and
fail-closed guarantees hold: a branch is deleted only on positive proof of
emptiness (some ref measures zero); a git error skips that ref rather than
counting as proof, and if no default ref is measurable the branch is preserved
and warned. Candidate refs are gathered in a new `default_base_refs` helper.

`override_local_or_default` now returns `refs/heads/<branch>` for the local
stacked start-point instead of the bare branch name, so a same-named tag
(`refs/tags/<branch>`) can no longer shadow the branch through gitrevisions
precedence. The local ref is already verified to exist by
`local_branch_ref_exists?`, so the fully-qualified form is unambiguous with no
downside; the human-readable warning still names the bare branch.

New regression in [[testing]]: `test_repoints_empty_placeholder_when_local_ahead_of_origin`
(inverse of the pass-01 origin-ahead test) — a placeholder at local master with
a lagging origin is re-pointed onto `origin/<prereq>` instead of preserved.
Verified to fail against pre-fix code. Refreshed [[modules/worktree]] for the
either-ref measurement basis.

Verification on this branch:

- `ruby -Itest -Ilib test/unit/worktree_test.rb` (29 runs, 0 failures)
- `bundle exec rubocop lib/hive/worktree.rb test/unit/worktree_test.rb`

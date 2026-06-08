---
ts: 2026-06-08T20:15:00Z
slug: babysitter-rebase-push-head-branch
tags: [babysitter, github, bugfix]
---

## Babysitter: auto-rebase must force-push to the PR head branch, not the internal worktree branch

**Bug (shipped in #422).** `PrFixer#auto_rebase` rebased a green-but-`BEHIND` PR's worktree cleanly, then force-pushed via `GhOps.force_push_with_lease(worktree.path, worktree.branch, …)`. `worktree.branch` is the babysitter's INTERNAL ref name `hive-babysitter/pr-<n>`, so the push targeted `origin/hive-babysitter/pr-<n>` — NOT the PR's real head branch. Worse, the bare `git push --force-with-lease` form has no local remote-tracking ref for that name, so it failed with "stale info". Net: the rebase was thrown away, the PR stayed `BEHIND`, and the babysitter emitted `action=rebase outcome=failure` every tick (verified live on PR #300, whose real head is `i-m-thinking-of-hivebox-260602-97bc`).

**Fix.**

- `GhOps.force_push_with_lease(worktree, branch, cfg:, dry_run:, expected_oid: nil)` — new optional `expected_oid`. When present (non-nil/non-empty) it uses the explicit lease form `git push --force-with-lease=<branch>:<expected_oid> origin HEAD:<branch>`, which protects against clobbering a concurrent push WITHOUT needing a local remote-tracking ref. When absent it keeps the backward-compatible bare `--force-with-lease`. Dry-run no-op and the `PushResult` return shape are unchanged.
- `PrFixer#auto_rebase(status, started)` now receives the status rollup (threaded from `handle_green`) and force-pushes to `@pr.fetch("headRefName")` with `expected_oid: status["headRefOid"] || @pr["headRefOid"]`. Fork PRs are excluded upstream, so `origin` is always the right remote.

**Tests.** `gh_ops_test`: bare lease (no `expected_oid`), explicit lease (`--force-with-lease=feature:abc123`), empty-string OID treated as bare, dry-run skips git. `pr_fixer_test`: green+BEHIND asserts the push targets `feature-branch` (NOT `hive-babysitter/pr-42`) with the rollup's `headRefOid`; plus the `@pr["headRefOid"]` fallback path and the `nil`→bare-lease path. Full `rake coverage` gate passed (4980 runs, 0 failures/0 errors, 100% line coverage). rubocop clean on changed files.

**Refreshed pages:**
- [[modules/babysitter]]
- [[commands/babysit]]

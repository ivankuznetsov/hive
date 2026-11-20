## 2026-11-20 — Reviewer reroutes no longer stale resolved plan reviews

- Symptom: on todero, Muse and Codex ran out of quota and the operator moved
  `plan_review.routes.primary`/`verification` from Muse to Grok (the adversary
  had already moved from Codex to Claude). Two tasks whose reviews had cleared
  and were already in 4-execute (`agent-and-app-api-v1-261105-7d3c`,
  `shared-wishlists-with-gift-reservations-261105-d8c8`) then failed execute
  entry with `plan review policy changed after resolution` and parked on the
  operator-owned `plan_review_blocked`. Reverting the reroute later would have
  staled every review cleared under the temporary routes.
- Cause: `Policy.policy_affecting_config` includes reviewer routing (`routes`,
  `reviewers`, review model routing) so that a fixed route un-stales an
  `unsupported` block. `TransitionGuard.freshness` compared that combined
  fingerprint for every review, resolved or not.
- Change: `Policy.configuration_current?` compares a resolved review
  (`skipped`, `cleared`, `degraded_cleared`) with its own reviewer routing put
  back. Only verdict-relevant drift (levels, coverage, protected paths, skip
  limits, classifier, adapter and its contract version) can stale it.
  Unresolved and blocked reviews still compare everything. Policy artifacts
  now record `reviewer_routing`. The orchestrator applies the same rule to the
  configuration and to the policy fingerprint, so a cleared review in `3-plan`
  is reused rather than rekeyed on a routing-only change.
- Legacy artifacts: the routing is rebuilt from the review's route receipts
  and trusted only when it reproduces the recorded digest. Both todero
  records rebuild exactly, so their next execute retry passes the guard once
  this ships.
- Pages: [[modules/plan_review]], [[stages/execute]], [[gaps]].

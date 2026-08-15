## 2026-08-15 — Plan-review exact coverage closure

The final exact-coverage pass adds regression evidence for plan-review paths
that are deliberately fail-closed or operator-facing and therefore were not
reached by the primary lifecycle scenarios:

- CLI dispatch and human-readable decision output, migration summaries, and
  the complete closed configuration rejection matrix.
- Invalid, conflicting, stale, unauthorized, and retry decision paths.
- Reviewer-route validation, planner-revision firewall failures, bounded
  revision exhaustion, failed candidate verification, and corrupt retained
  artifacts.
- Transition freshness, legacy adoption, task metadata/action fallbacks, and
  the TUI guarded-command mismatch.

The tests preserve the production contracts; they do not weaken the exact
100% line gate or convert defensive branches into exclusions.

See [[modules/plan_review]] and [[testing]].

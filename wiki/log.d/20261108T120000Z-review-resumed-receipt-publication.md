# 2026-11-08 — Publish resumed fix receipts before pre-cap reviewers

- A restart that advances past a completed pass with an admissible
  (`fixed`/`approved`/`ci_repaired`) receipt bound to HEAD now publishes that
  head before entry CI and reviewers, not only in verify-only mode.
- Closes the crash window between writing `fix-success-NN.md` and publication
  when `max_passes` leaves the next pass pre-cap (plan U2 restart ordering).
- Regression: `test_restart_after_unpublished_pre_cap_fix_receipt_publishes_before_reviewers`.

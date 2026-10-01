# 2026-10-01 — Auto-rebase leaves a head-bound guardrail approval alone

- hivedev C1 paused at `REVIEW_WAITING reason=fix_guardrail head=c51da0f`.
  After the operator ticked every line, `hive run`'s auto-rebase rewrote the
  branch to 6ad1511 (a content-preserving rebase past a squash-merged
  dependency). The resume then failed with `approval_head_mismatch`, and the
  approval was lost.
- `Run#perform_rebase` now returns
  `Result.skipped(:pending_head_bound_approval)` while the marker is
  `REVIEW_WAITING reason=fix_guardrail` with a `head=` binding. The rebase
  happens on the run after the approved pass advances. Legacy markers without
  `head=` still rebase. The new reason is added to the `hive-run.v2` schema
  enum.
- Gap: `hive rebase-status` does not yet preview this skip.

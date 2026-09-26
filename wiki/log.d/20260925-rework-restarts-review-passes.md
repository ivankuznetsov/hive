# 2026-09-25 — Outcome-evidence rework restarts review passes

- `hive evidence rework` now moves the task's pass-numbered review files
  (`reviews/*-NN.md`: reviewer outputs, escalations, fix-success, errors) into
  `reviews/archive/rework-NN/` when it returns the task to 4-execute. Review
  derives its pass number from those top-level files and refuses once they
  exceed `review.max_passes + 1`, so after a rework the next review continued
  at passes 03/04 and then failed with "review pass NN=4 exceeds
  review.max_passes=2"; a reworked task could never be reviewed again.
  Archived passes are kept for provenance; non-pass files stay in place.

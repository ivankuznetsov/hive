---
date: 2026-06-18
slug: ce-review-p3-polish
pages: [stages/review, modules/reviewers]
---

Cleared the three deferred P3 findings from the /ce-code-review of PR #512.

- **Wall-clock clamp on the triage retry.** `run_triage_with_retries` now takes
  `started_at:`/`max_wall_clock_sec:` and bails to `:wall_clock_exceeded` before
  starting another spawn when the review budget is spent; the caller turns that
  into `REVIEW_STALE reason=wall_clock`, mirroring `run_reviewers`. Prevents a
  high `review.triage.max_attempts` × 1800s triage timeout from overrunning
  `review.max_wall_clock_sec`.
- **Single backoff formula.** Added `Hive::Reviewers.backoff_seconds_for`; the
  reviewer adapters (`Agent`, `CodexReview`) and `triage_retry_backoff` now
  delegate to it instead of each carrying its own
  `[2**(n-1), REVIEWER_BACKOFF_CAP_SEC].min` copy. Each keeps a thin wrapper as
  a test-stub seam.
- **One truncation primitive.** `truncate_marker_message` gained `max:`/`ellipsis:`
  params; `review_phase_error_summary` reuses it (300-char cap, single-char
  ellipsis) instead of duplicating the truncate-with-ellipsis logic. Output is
  byte-for-byte identical to before for both callers.

Unit coverage: added a wall-clock-bail test for `run_triage_with_retries`.
`run_review_test.rb` (50), `run_reviewers_test.rb` (69), and the phase-failure
helper unit tests (10) all green; rubocop clean.

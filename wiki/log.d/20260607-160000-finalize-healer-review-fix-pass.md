## [2026-06-07T16:00:00Z] review fix-pass — finalize unpushed healer hardening

**Action:** Applied 6-review findings to `Hive::Daemon::StaleAgentHealer` and its tests. Collapsed duplicated marker reason helpers into one `marker_reason(row)`, extracted the review-path heal-label ternary into `review_heal_label`, and documented the intentional silent no-op when `clear_current` returns false (no event, no retry budget consumed). Added a dispatcher-level integration test proving finalize re-dispatches (not `:record_baseline`) after the unpushed-commits clear via the seeded pre-clear mtime, plus unit tests for clear-false-no-budget, duplicate rows in one heal pass, and per-process budget reset on a fresh healer instance. Strengthened existing assertions with explicit non-default mtime, `Markers.current.none?`, and `refute marker_heal_failed` on negative skips. Noted in [[modules/daemon]] that the recovery budget is in-memory and resets on restart/SIGHUP reload.

**Refreshed pages:**
- [[modules/daemon]]

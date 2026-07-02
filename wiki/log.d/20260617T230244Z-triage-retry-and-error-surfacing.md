---
date: 2026-06-17
slug: triage-retry-and-error-surfacing
pages: [stages/review, gaps, testing]
---

Diagnosed a real stuck task (`xbookmark` #1333 "Add an X bookmarks feature",
slug `we-need-to-add-an-260616-094b`) parked in `6-review`. Root sequence:
codex reviewer hit a ChatGPT usage limit in the morning (resolved on reset),
but every full run then failed at the **triage** phase ~5.5 min in
(`REVIEW_ERROR phase=triage reason=triage_failed`, no `retry_after`, so the
daemon never auto-retried). Two failures couldn't be diagnosed because
`mark_review_phase_failure` only used `triage_result.error_message` to test for
a provider limit and then **discarded** it — the terminal marker recorded only
a bare `reason=triage_failed`, which `marker_summary` (web `diagnostic.summary`
+ `status.md`) and the bot surfaced as a contentless "the review agent
crashed."

Two changes in `lib/hive/stages/review.rb`:

1. **Surface the cause.** `mark_review_phase_failure` now stamps
   `message="<condensed error>"` (new `REVIEW_PHASE_ERROR_SUMMARY_MAX = 300`
   cap, whitespace-collapsed, ellipsised) on the non-limit `:review_error`
   marker via new helper `review_phase_error_summary`. Applies to every caller
   (triage / fix / ci). `Hive::Markers.format_attr` already sanitizes quotes,
   newlines, and `<!--`/`-->`; nil/blank collapses to no attr.

2. **Retry transient triage.** Triage previously ran exactly once (reviewers
   already retry). New `run_triage_with_retries` mirrors the per-reviewer
   budget: retries a transient `:error` up to `review.triage.max_attempts`
   (default `Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS = 2`) with the same
   exponential backoff capped at `REVIEWER_BACKOFF_CAP_SEC = 8`
   (`triage_retry_backoff`, extracted as a stubbable seam). `:ok`, `:tampered`,
   and provider-limit outcomes short-circuit (a retry would repeat a tamper;
   a limit self-heals via `retry_after`).

Tests (`test/integration/run_review_test.rb`): updated
`test_triage_non_limit_error_stays_terminal_triage_failed` and
`test_triage_tampered_and_error_statuses_yield_review_error` to stub
`triage_retry_backoff` (keeps them sleepless) and assert the new `message`
attr; added `test_triage_transient_error_is_retried_then_recovers` (error
once → `:ok`, asserts two triage calls and recovery to `review_waiting`).
Added `test/unit/stages/review/phase_failure_helpers_test.rb` so the 100%
coverage gate also covers long-message truncation and the real capped backoff
helper without sleeping.
Full `run_review_test.rb` (50) + markers/task_action/status/web-dispatcher/
notification-builders/run_reviewers unit suites green; rubocop clean.

Updated [[stages/review]] (triage retry + `message=` surfacing). Recorded in
[[gaps]] that the underlying ~5.5-min triage failure cause on the live box is
still unconfirmed — the surfacing fix is what will reveal it on the next run;
leading hypotheses are a transient `tmux has-session` failure under swap
exhaustion (no OOM-kill in the kernel log; the box had 130 agent procs and
full swap) misread as `tmux_session_terminated`, or the interactive `claude`
agent ending its turn before writing `escalations-NN.md`. Did not edit
compiled [[log]]; page coverage unchanged so [[index]] not edited.

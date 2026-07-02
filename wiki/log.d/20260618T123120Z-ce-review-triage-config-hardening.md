---
date: 2026-06-18
slug: ce-review-triage-config-hardening
pages: [stages/review, state-model]
---

Addressed /ce-code-review findings on the triage-retry / error-surfacing
change (PR #512) before merge.

P2 (cross-reviewer, 4 personas): the new `review.triage.max_attempts` knob had
neither load-time validation nor a runtime rescue, unlike every sibling
`max_attempts`. A non-integer value reached a bare `Integer(value)` in
`triage_max_attempts` and crashed the whole 6-review run as an opaque
`runner_exception`; `0`/negative silently ran triage once. Fixed by adding
`review.triage.max_attempts` to `Hive::Config::POSITIVE_INTEGER_KEYS` (rejected
at load with a typed ConfigError like `review.ci.max_attempts`) and giving
`triage_max_attempts` a clamp (`[Integer(value), 1].max`) plus an
`ArgumentError`/`TypeError` rescue that warns and falls back to the default —
defense-in-depth for programmatic/test configs that bypass validation, mirroring
`Hive::Reviewers::Agent#max_attempts_from_spec`.

P2 (project-standards): doc/comment claimed the `message=` attr is written for
"triage / fix / ci". The CI phase does not route through
`mark_review_phase_failure` — a CI failure writes `REVIEW_ERROR phase=ci
reason=ci_unrunnable` directly and carries no `message=`. Corrected the
`review.rb` helper comment (`fix_error` → `fix_failed`), [[stages/review]], and
[[state-model]] to say triage/fix only.

Added unit coverage in `test/unit/stages/review/phase_failure_helpers_test.rb`:
`review_phase_error_summary` exact-limit/blank/whitespace-collapse branches, and
`triage_max_attempts` default/explicit/clamp/non-integer-fallback. Lower-priority
findings deferred (no wall-clock clamp on the triage retry — default-safe at
max_attempts=2; the third copy of the backoff formula; the
`review_phase_error_summary` vs `truncate_marker_message` overlap). rubocop
clean; `run_review_test.rb` (50) green.

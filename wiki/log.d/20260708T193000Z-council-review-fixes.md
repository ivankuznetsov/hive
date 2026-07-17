## [2026-07-08T19:30:00Z] workflows - council review-pass hardening

**Action:** Fixed a batch of council robustness/correctness issues surfaced in
review. `Hive::Stages::Council#run!` now runs a pre-flight on the current marker
(a `COMPLETE` council short-circuits without re-spawning reviewers; a `WAITING`
council resumes by re-triaging the same round instead of opening a new one) and
rescues `SystemCallError` so a file renamed/deleted between parse and run writes
an attributed `:error` marker (`reason=council_io_error`) instead of crashing.
`next_round` derives its glob dir from `triage_output` so custom triage dirs
track rounds correctly. Deterministic triage no longer sniffs free-text prose
for readiness — a missing structured `Verdict:`/`Status:` line defaults to
not-ready — and the "Rejected findings" placeholder wording clarifies it is not
derivable by deterministic triage. Reviewer `max_attempts` is now honored via a
retry loop.

**Parser/base:** `parse_reviewers` rejects duplicate reviewer `name`/
`output_basename` (both resolve to the same review file), a parse-time warning
fires when a `revise` agent is paired with `max_rounds: 1` (a silent no-op), and
`spawn_agent` logs a note (`config-warnings.log`) when a non-`:claude` profile
sets `model`/`effort` (only applied on claude). The `reviews/triage.md` default
is hoisted to `Hive::Workflow::DEFAULT_TRIAGE_OUTPUT` (single source of truth).

**Tests:** Added council tests for failed-reviewer `:error` markers, explicit
`input:` resolution, resume-after-waiting round continuity, and `COMPLETE`
short-circuiting; extended triage-content assertions to Accepted/Rejected
sections.

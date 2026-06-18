---
date: 2026-06-18
slug: review-p3-polish-audit
pages: [modules/reviewers, testing, gaps]
---

Refreshed wiki planning/documentation coverage after commit `c4045dfe`
cleared the deferred PR #512 review polish items. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "review triage wall clock backoff
truncation reviewers"` surfaced the existing [[stages/review]] coverage; no
relevant configured master-wiki match was found.

Inspected the committed diff plus current `lib/hive/reviewers.rb`,
`lib/hive/reviewers/agent.rb`, `lib/hive/reviewers/codex_review.rb`,
`lib/hive/stages/review.rb`,
`test/unit/stages/review/phase_failure_helpers_test.rb`,
`test/unit/stages/review/run_reviewers_test.rb`, and reviewer tests. The
committed [[stages/review]] update already documents that transient triage
retry now honors `review.max_wall_clock_sec` before starting another spawn.
Updated [[modules/reviewers]] for the shared `Hive::Reviewers.backoff_seconds_for`
formula used by Agent, CodexReview, and triage retry wrappers; updated
[[testing]] for the new wall-clock-bail helper coverage; and amended [[gaps]]
to keep the live triage-failure uncertainty open while noting that `c4045dfe`
only source/test-pins the retry clamp. Page count stayed 80, so [[index]] did
not need a catalog update. Did not edit compiled [[log]] and did not run
`qmd update` or `qmd embed`.

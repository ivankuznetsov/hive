---
date: 2026-06-18
slug: review-phase-helper-coverage-audit
pages: [testing, gaps, index]
---

Refreshed wiki planning/documentation coverage after commit `e5c26edc`
added `test/unit/stages/review/phase_failure_helpers_test.rb` and amended
the existing triage retry/error-surfacing log fragment. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first; `qmd search "triage retry error surfacing review phase failure helpers"` found the current [[stages/review]] coverage and no relevant configured master-wiki hit was found.

Inspected the committed diff plus current `lib/hive/stages/review.rb`,
`test/unit/stages/review/phase_failure_helpers_test.rb`,
`test/integration/run_review_test.rb`, [[stages/review]], [[testing]], and
[[gaps]]. [[stages/review]] was already source-synced for
`run_triage_with_retries`, `review.triage.max_attempts`, capped backoff, and
bounded terminal `message=` surfacing. Updated [[testing]] to list the new
unit helper suite and to describe the integration coverage for transient
triage retry recovery plus terminal triage `message=` surfacing. Updated
[[gaps]] to carry forward that the helper tests do not close the live
~5.5-minute triage failure uncertainty; the next live failure still needs the
new `message=` attr to identify the underlying trigger. Page count stayed 80;
[[index]] freshness metadata was bumped only because coverage metadata changed.
Did not edit compiled [[log]] and did not run `qmd update` or `qmd embed`.

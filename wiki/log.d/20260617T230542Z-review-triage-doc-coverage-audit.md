---
date: 2026-06-18
slug: review-triage-doc-coverage-audit
pages: [state-model, modules/markers, testing, stages/review]
---

Audited the post-commit wiki coverage for commit `094dbb25`
(`fix(review): retry transient triage failures and surface the real error`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], recent [[log]] entries, and the committed triage refresh fragment
first. Per project protocol, ran read-only
`qmd search "triage retry review phase error message REVIEW_ERROR"`; the index
still reflected pre-refresh text, so verification used the committed diff plus
direct source/wiki reads and the configured master wiki path, which had no
matching prior context.

Confirmed [[stages/review]] and [[gaps]] already captured the main behavior:
`run_triage_with_retries` mirrors reviewer retry budgets for transient triage
errors, `review.triage.max_attempts` defaults to
`Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS`, tamper and provider-limit
outcomes short-circuit, and non-limit phase failures now stamp a capped
`message=` attr. Refreshed adjacent marker/testing coverage so
[[modules/markers]] and [[state-model]] document the optional `message=` attr
on `REVIEW_ERROR`, and [[testing]] plus [[stages/review]] mention the new
transient triage retry and message-surfacing assertions in
`test/integration/run_review_test.rb`.

No new page was added, so [[index]] page coverage did not change. The live
root cause of the original ~5.5-minute triage failure remains uncertain and is
still recorded in [[gaps]]; the next live failure should now expose the cause
through the marker `message=` attr. Did not edit compiled [[log]] and did not
run `qmd update` or `qmd embed`.

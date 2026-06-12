---
date: 2026-06-12
slug: review-remediation-surface-audit
pages: [commands/web, commands/drop, testing, gaps]
---

Post-commit command/API surface audit for `65e90ebe`
(`fix(hivebox): review remediation - round transitions, honest failures`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "hivebox review remediation red task retry recovery heal_requeue_failed answers controller drop pr_closed status broadcaster"`
returned no indexed hits, and the configured master wiki path had no matching
context.

Inspected the committed diff plus current `lib/hive/commands/drop.rb`,
`lib/hive/daemon/logger.rb`, `lib/hive/daemon/stale_agent_healer.rb`,
`lib/hive/web/dispatcher.rb`, `lib/hive/web/status_feed.rb`,
`web/app/models/status_broadcaster.rb`, `web/app/controllers/tasks_controller.rb`,
`web/app/helpers/application_helper.rb`, `web/app/javascript/controllers/answers_controller.js`,
`web/app/javascript/controllers/project_filter_controller.js`, relevant Rails
views, focused unit/integration/system tests, and the affected wiki pages.
Confirmed existing pages already covered the data-model queue/status-broadcaster
shape, `heal_requeue_failed`, web Retry recovery, and most hivebox remediation.
Refreshed [[commands/web]] to document Q&A form morph behavior and marker-only
markdown-comment stripping, bumped [[commands/drop]] for the clarified
`pr_closed` contract, corrected stale hivebox status-broadcast test coverage in
[[testing]], and refined [[gaps]] for the remaining Advanced Drop live-smoke
uncertainty. Page coverage did not change, so [[index]] required no catalog
change. Verified the fragment with `bundle exec ruby -Itest
test/unit/wiki_log_test.rb`. Did not edit compiled [[log]], `qmd update`, or
`qmd embed`.

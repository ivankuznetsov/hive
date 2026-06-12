---
date: 2026-06-12
slug: web-recovery-route-audit
pages: [architecture, commands/web, testing, gaps]
---

Post-commit command/API surface audit for `9d0fc9ef`
(`feat(hivebox): Retry button + diagnostic banner for red tasks`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first, then checked [[architecture]] before
editing.
Read-only `qmd search "hivebox web recovery retry diagnostic banner red task"`
returned no indexed hits; direct wiki/master-wiki search found older diagnostic
and route/command history, but not this new task-page route.

Inspected the committed diff plus current `lib/hive/web/dispatcher.rb`,
`web/config/routes.rb`, `web/app/controllers/tasks_controller.rb`,
`web/app/helpers/application_helper.rb`, `web/app/views/tasks/_state.html.erb`,
`lib/hive/bot/handlers/recovery_sequence.rb`,
`lib/hive/bot/notification_builders.rb`,
`test/unit/web/dispatcher_test.rb`, and `web/test/integration/tasks_test.rb`.
Refreshed [[commands/web]] for `POST /tasks/:project/:slug/recover`, the
diagnostic banner, and the `trigger=web_recover` daemon-queue sequence; refreshed
[[architecture]] so the hivebox mutation summary includes web recovery via the
bot `RecoverySequence`; refreshed [[testing]] for the new unit/Rails integration
contracts; and refreshed [[gaps]] to record that source/Rails integration
coverage plus commit-message live verification exist, while browser-system/Docker
artifacts remain absent. Page coverage did not change, so [[index]] was not
edited. Did not run tests, `qmd update`, or `qmd embed`.

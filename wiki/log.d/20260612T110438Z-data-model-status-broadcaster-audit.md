---
date: 2026-06-12
slug: data-model-status-broadcaster-audit
pages: [state-model, commands/web, modules/daemon, testing, gaps, index]
---

Post-commit data-model coverage audit after `65e90ebe`
(`fix(hivebox): review remediation - round transitions, honest failures`)
touched the Rails model `web/app/models/status_broadcaster.rb` plus daemon
queue/healer and web dispatcher/controller paths. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[dependencies]],
[[gaps]], and recent compiled [[log]] entries first. `qmd search
"hivebox status broadcaster web dispatcher stale agent healer recovery route
task state"` returned no indexed hits, and the configured master wiki had no
matching context.

Inspected the committed diff plus current `web/app/models/status_broadcaster.rb`,
`lib/hive/web/status_feed.rb`, `lib/hive/web/dispatcher.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`,
`lib/hive/daemon/stale_agent_healer.rb`, `lib/hive/commands/drop.rb`,
`web/app/controllers/tasks_controller.rb`, `web/app/controllers/repos_controller.rb`,
focused broadcaster/status-feed/dispatcher/healer tests, and the touched wiki
pages. Confirmed no `web/db/*_schema.rb` or migration file changed; the model
touch is a non-ActiveRecord Turbo bridge over `hive status` snapshots. Refreshed
[[state-model]] so the data-model page now covers the global dispatch-request
JSON queue, `.claimed` / `.claim` / `.sequence` files, web recovery sequence
cleanup, `StatusFeed` snapshot/dedup semantics, and `StatusBroadcaster`'s
refresh-before-projects-frame ordering. Corrected [[commands/web]] so dedup is
attributed to `StatusFeed`, added [[modules/daemon]] coverage for
`heal_requeue_failed` and web sequence continuations, updated [[testing]] for
the new focused coverage, and refined [[gaps]] for the remaining no-live-smoke
and no-focused-refresh-order-test uncertainty. Page coverage metadata changed
because [[state-model]] now names the web model and daemon queue sources, so
[[index]] was bumped. Did not edit compiled [[log]], run tests, `qmd update`, or
`qmd embed`.

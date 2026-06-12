---
date: 2026-06-11
slug: web-drop-task-audit
pages: [architecture, commands, commands/web, commands/drop, testing, gaps]
---

Post-commit audit for `4a09cdb9` (`feat(hivebox): Drop task card in Advanced
— Shift+X parity`). Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], and recent compiled [[log]] entries
first. `qmd search "hivebox drop task Advanced Shift X dispatcher tasks
controller routes"` returned no indexed hits; local wiki search found the new
drop references in [[commands/web]], [[commands/drop]], and the existing TUI
Shift+X coverage.

Inspected the committed diff plus current `lib/hive/web/dispatcher.rb`,
`web/app/controllers/tasks_controller.rb`, `web/config/routes.rb`,
`web/app/views/tasks/show.html.erb`, `lib/hive/commands/drop.rb`,
`test/unit/web/dispatcher_test.rb`, and `web/test/integration/tasks_test.rb`.
Refreshed command/API coverage so the web Drop route is documented as an
in-process `Commands::Drop` call, not a daemon queue request; the task page
posts the rendered stage as `from`, so a stale page raises `Hive::WrongStage`
and renders 422 without deleting the moved task. Refreshed [[commands/web]]
frontmatter/TLDR for the gem-side `lib/hive/web/` dispatcher path, refreshed
[[testing]] for the new dispatcher/integration coverage, and recorded the
remaining live-browser / Docker smoke gap in [[gaps]]. Page coverage did not
change, so [[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`.

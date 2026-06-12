---
date: 2026-06-11
slug: hivebox-rail-composer-audit
pages: [commands/web, gaps]
---

Post-commit command/API coverage audit for `24c41980`
(`feat(hivebox): rail selection preselects the composer + Add project link`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hivebox project filter
composer add project"` returned no indexed hits; the configured master wiki only
had broad Rails/wiki context.

Inspected the committed diff plus current
`web/app/javascript/controllers/project_filter_controller.js`,
`web/app/views/status/index.html.erb`,
`web/app/assets/stylesheets/application.css`,
`web/config/routes.rb`, `web/app/controllers/status_controller.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the follow-up keeps the
project rail client-side: explicit project clicks now sync the composer select,
filtered deep links preselect only when the composer is unset, widening back to
All projects preserves the chosen project, and `+ Add project` is a Repos link
rather than a filter button. Updated [[commands/web]] to document those surface
and system-test contracts, and updated [[gaps]] so the hivebox residual entry
carries the `24c41980` source/test evidence while the deployed/live-agent
uncertainty remains open. Page coverage did not change, so [[index]] was not
edited. Did not run tests, `qmd update`, or `qmd embed`.

---
date: 2026-06-11
slug: hivebox-project-filter-audit
pages: [commands/web, gaps]
---

Post-commit command/API coverage audit for `70d60980`
(`feat(hivebox): project filter rail + select polish`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hivebox project filter
rail select placeholder status projects"` returned no indexed hits; the
configured master wiki only had broad Rails/wiki context.

Verified the committed diff plus current `web/app/javascript/controllers/project_filter_controller.js`,
`web/app/views/status/index.html.erb`, `web/app/views/status/_projects.html.erb`,
`web/app/assets/stylesheets/application.css`, `web/config/routes.rb`,
`web/app/controllers/status_controller.rb`, Stimulus controller autoloading, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the rail adds no route or
handler: it filters the already-rendered status grid client-side, mirrors the
choice into `?project=` with `history.replaceState`, and re-applies after Turbo
Stream replace/morph updates. The composer project select now uses a
disabled+hidden placeholder via `select_tag`, and global select styling draws a
custom chevron. Updated [[commands/web]] so the Tests section names the
project-rail system coverage, and updated [[gaps]] so the hivebox residual entry
carries the `70d60980` evidence while the deployed/live-agent uncertainty
remains open. Page coverage did not change, so [[index]] was not edited. Did not
run `qmd update` or `qmd embed`.

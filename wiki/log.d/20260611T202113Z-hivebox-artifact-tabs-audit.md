---
date: 2026-06-11
slug: hivebox-artifact-tabs-audit
pages: [commands/web, gaps]
---

Post-commit audit for `c52e4e83` (`style(hivebox): artifact tabs are
chrome, documents are documents`). Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "hivebox artifact tabs documents"` returned no indexed hits; the
configured master wiki only had broad Rails/markdown context. Verified the
committed diff in `web/app/assets/stylesheets/application.css` plus the current
task page view (`web/app/views/tasks/show.html.erb`), artifact controller, and
web tests covering markdown rendering, artifact ordering, log placement, and
open-state preservation.

Refreshed [[commands/web]] so the task page docs distinguish artifact
summaries as filename-tab UI chrome from rendered markdown document panels.
Carried uncertainty forward in [[gaps]]: no checked-in screenshot,
visual-regression artifact, live Docker smoke, or long-running-agent hivebox
run proves the artifact-tab/document visual distinction in a browser. Page
coverage did not change, so [[index]] was not edited. Did not run `qmd update`
or `qmd embed`.

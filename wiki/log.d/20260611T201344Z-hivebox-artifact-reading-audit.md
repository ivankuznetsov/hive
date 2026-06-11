---
date: 2026-06-11
slug: hivebox-artifact-reading-audit
pages: [commands/web, dependencies, testing, gaps]
---

Post-commit wiki coverage audit for `d7ce55a9`
(`feat(hivebox): finalize-first artifacts, markdown rendering, log last`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "routes handlers commands executable entrypoints README hivebox"`
returned no indexed hits, so verification used the committed diff, direct
source reads, and targeted `rg` over the configured master wiki path plus
project docs/wiki.

Inspected `web/config/routes.rb`, `web/app/controllers/tasks_controller.rb`,
`web/app/helpers/application_helper.rb`, `web/app/views/tasks/show.html.erb`,
`web/Gemfile`, `web/Gemfile.lock`, `web/test/integration/tasks_test.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the route table did not
change; the surface change is task-page behavior: `TasksController` now orders
artifacts chronologically until `8-finalize`/`9-done`, then puts `artifact.md`
first so the deliverable opens by default; the task view renders artifacts
before the log; and `ApplicationHelper#render_markdown` uses Redcarpet with
GFM tables/fenced code/autolinks, drops leading YAML front matter, escapes raw
HTML before rendering, and sanitizes the rendered output with an explicit
allowlist.

Existing [[commands/web]] coverage already matched the handler/view behavior,
including the Redcarpet and finalize-first artifact details. Refreshed
[[dependencies]] so the separate Rails web bundle and its Redcarpet dependency
are covered, refreshed [[testing]] so the Rails integration layer mentions
artifact ordering/markdown/log-layout regressions, and updated [[gaps]] to
include `d7ce55a9` in hivebox's source-pinned-but-not-live-Docker-smoked
coverage. Page coverage did not change, so [[index]] did not need a catalog
update. Did not run `qmd update` or `qmd embed`.

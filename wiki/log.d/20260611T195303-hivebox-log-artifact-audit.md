---
date: 2026-06-11
slug: hivebox-log-artifact-audit
pages: [commands/web, testing, gaps]
---

Post-commit command/API-surface audit for `eb971b55`
(`fix(hivebox): logs and artifacts are readable while live-updating`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. `qmd search
"hivebox log tail artifact details poll controller turbo permanent"` returned
no indexed hits, so verification used the committed diff plus direct source
reads.

Inspected the changed Stimulus controllers and views:
`web/app/javascript/controllers/poll_controller.js`,
`web/app/javascript/controllers/artifacts_controller.js`,
`web/app/views/tasks/show.html.erb`, and `web/app/views/tasks/_log.html.erb`,
plus `web/config/routes.rb`, `web/app/controllers/tasks_controller.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the route/API surface did
not add a new endpoint: the task page still uses `GET
/tasks/:project/:slug/log` rendered by `TasksController#log`, but the log
frame is now `data-turbo-permanent`, current source gives its own frame reloads
`refresh: "morph"`, and its poll controller follows the tail, pauses reloads
while scrolled up, and resumes at the bottom. Artifact details now preserve
operator open/closed state only across Turbo morphs while content continues to
update.

Existing [[commands/web]] coverage already described the new behavior. Refreshed
[[testing]] so `web/test/system/pipeline_flow_test.rb` includes the log-tail and
artifact-morph regressions, and narrowed [[gaps]]: `tasks#log` is no longer an
uncovered browser happy path, while live Docker / long-running-agent evidence
for this reading behavior remains absent. Page coverage did not change, so
[[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`.

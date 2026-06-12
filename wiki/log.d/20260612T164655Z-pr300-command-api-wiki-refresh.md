---
date: 2026-06-12
slug: pr300-command-api-wiki-refresh
pages: [architecture, decisions, cli, commands/web, commands/drop, modules/daemon, state-model, stages/index, stages/plan, testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`279a9380` touched hivebox routes/controllers, dispatch handlers, Docker
installers, the `hive-drop` schema, daemon healing, and the manual web demo
recorder. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], and recent compiled [[log]] entries
first. Read-only `qmd search "routes handlers commands executable entrypoints
README hivebox"` against the project and master collections returned no hits,
so verification used the committed diff plus direct source reads.

Inspected `lib/hive.rb`, `lib/hive/daemon/stale_agent_healer.rb`,
`lib/hive/web/dispatcher.rb`, `lib/hive/web/supervisor.rb`,
`web/app/controllers/application_controller.rb`,
`web/app/controllers/repos_controller.rb`, `web/app/controllers/tasks_controller.rb`,
`web/config/routes.rb`, `web/script/record_box_demo.rb`,
`packaging/docker/install-box.sh`, `packaging/docker/install-box.ps1`,
`schemas/hive-drop.v1.json`, `schemas/hive-drop.v2.json`, and focused unit /
integration tests around web dispatch, auth, schema files, stale-agent healing,
web command boot, Docker installer argv, and hivebox status/log behavior.

Updated [[commands/web]], [[architecture]], and [[decisions]] for request-time
owner re-check and session eviction, clone process-group timeout and partial
target cleanup, bounded task log tail reads, queue-grammar 422s, the manual
`web/script/record_box_demo.rb` entrypoint, and installers binding
`127.0.0.1` by default with `HIVEBOX_BIND` as the opt-out. Updated
[[commands/drop]] and [[cli]] so `hive drop --json` is documented as current
`hive-drop.v2` with v1 retained for pinned validators. Updated
[[modules/daemon]], [[state-model]], [[stages/index]], and [[stages/plan]] so
`3-plan` requeue coverage includes any successful terminal `ERROR` clear there,
including elapsed `limits_reached`, not only terminal agent loss. Updated
[[testing]] for the new unit/test coverage and [[gaps]] for remaining live
smoke gaps, the unrun demo recorder, and the observed copied v1 `$id`/title
metadata in `schemas/hive-drop.v2.json`.

Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

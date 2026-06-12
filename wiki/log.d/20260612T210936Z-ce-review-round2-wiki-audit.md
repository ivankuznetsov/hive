---
date: 2026-06-12
slug: ce-review-round2-wiki-audit
pages: [commands/web, commands/daemon, modules/daemon, state-model, decisions, testing, gaps]
---

Post-commit command/API and route-handler wiki refresh after commit `c0630426`
fixed ce-code-review round-2 findings across hivebox controllers, Docker
entrypoints/docs, dispatch-request schemas, and web integration tests. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. Read-only
`qmd search "hivebox health deep daemon pidfile dispatch request v2 healer task
diff bounded telegram numeric chat id clone target"` returned no exact indexed
hits; a targeted search of the configured master wiki path also found no
project-relevant prior pattern.

Inspected the committed diff and current source for `lib/hive.rb`,
`lib/hive/daemon/dispatch_request_queue.rb`,
`schemas/hive-dispatch-request.v2.json`, `schemas/hive-drop.v2.json`,
`web/config/routes.rb`, `web/app/controllers/health_controller.rb`,
`web/app/controllers/repos_controller.rb`,
`web/app/controllers/tasks_controller.rb`,
`web/app/controllers/telegram_controller.rb`,
`web/app/views/tasks/diff.html.erb`, `packaging/docker/Dockerfile`,
`packaging/docker/README.md`, `packaging/docker/compose.example.yml`, focused
daemon/schema tests, and the web integration tests for health, repos, tasks,
and Telegram setup.

Updated [[commands/web]] for strict Telegram chat-ID parsing before network
calls/saves, non-directory repo clone-target refusal, bounded task diff
rendering (`HIVEBOX_DIFF_TIMEOUT_SEC`, process group, tempfile, 512 KiB cap),
and `/health?deep=1` daemon-pidfile semantics used by the Docker healthcheck.
Updated [[commands/daemon]], [[modules/daemon]], [[state-model]], and
[[decisions]] so the dispatch-request queue documents current
`hive-dispatch-request.v2`, the `bot|healer` requestor enum, strict version
rejection, and claimed files staying schema-valid for the version produced.
Updated [[testing]] for the new schema
identity coverage plus the health/repos/tasks/telegram Rails integration
coverage. Updated [[gaps]] to close the obsolete `hive-drop.v2` copied-v1
metadata note while preserving live-browser/Docker/provider uncertainty.

Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

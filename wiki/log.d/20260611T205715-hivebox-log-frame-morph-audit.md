---
date: 2026-06-11
slug: hivebox-log-frame-morph-audit
pages: [commands/web, testing, gaps]
---

Post-commit wiki coverage audit for `463fff29`
(`fix(hivebox): log refreshes morph in place -- no more 3s blink`). Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first. `qmd search "hivebox task log artifact
turbo morph refresh"` returned no indexed hits, so verification used the
committed diff, direct source reads, and targeted `rg` over the configured
master wiki path plus project docs/wiki.

Inspected `web/app/views/tasks/show.html.erb`,
`web/app/views/tasks/_log.html.erb`, `web/app/javascript/controllers/poll_controller.js`,
`web/app/javascript/controllers/artifacts_controller.js`,
`web/app/controllers/tasks_controller.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed the code keeps the log
inside the existing `tasks#log` turbo-frame surface, adds `refresh: "morph"` to
the turbo-permanent log frame, and pins the no-blink contract with a Playwright
system assertion that a tagged `pre[data-tail-follow]` DOM node survives a poll
refresh that brings in a new log line.

Refreshed [[commands/web]] and [[testing]] so the browser coverage explicitly
mentions node-preserving log-frame morph reloads, and updated [[gaps]] so the
remaining uncertainty is only live Docker / long-running-agent evidence for the
same behavior against a deployed hivebox while real agents append logs and
artifacts. Page coverage did not change, so [[index]] did not need a catalog
update. Did not run `qmd update` or `qmd embed`.

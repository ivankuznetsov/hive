---
date: 2026-06-15
slug: golden-path-slug-capture-audit
pages: [testing, gaps]
---

Audited commit `d76b3f60` (`test(web): capture golden-path slug before
navigation`) after it touched `web/test/e2e/golden_path_e2e.rb`, [[testing]], and
`wiki/log.d/20260615T080111Z-golden-path-slug-capture.md`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent compiled
[[log]] entries first. `qmd search "golden path slug capture Capybara stale
task row"` found the current testing/gaps coverage; the configured master wiki
path only had generic Capybara/Turbo guidance.

Verified the committed diff plus current `web/test/e2e/golden_path_e2e.rb`, the
status-grid `.task-slug` markup in `web/app/views/status/_projects.html.erb`,
the prior golden-path DOM-race wiki fragments, and [[testing]]. The current test
uses `task_slug_from_grid!` before `click_task_link!`, then passes that captured
slug to the daemon log/mtime answer-window guard, matching the updated testing
page. Updated [[gaps]] so the golden-path CI uncertainty records the PR #480
`NameError` fix and carries forward the remaining lack of an in-tree hosted
`hivebox web (Rails tests + system)` pass artifact after that fix. Page coverage
did not change, so [[index]] did not need a catalog update. Did not run `qmd update`
or `qmd embed`.

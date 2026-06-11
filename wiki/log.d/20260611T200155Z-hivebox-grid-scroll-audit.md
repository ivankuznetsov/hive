---
date: 2026-06-11
slug: hivebox-grid-scroll-audit
pages: [commands/web, testing, gaps]
---

Post-commit wiki coverage audit for `0dea8aa6`
(`fix(hivebox): grid updates no longer reset page scroll`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search` for `hivebox grid scroll preserve
turbo morph status index composer permanent system test` and `Turbo morph
scroll preserve data turbo permanent composer Rails status index` returned no
indexed hits, so verification used the committed diff, direct source reads,
and targeted `rg` over the configured master wiki path plus project docs/wiki.

Inspected `web/app/views/status/index.html.erb`,
`web/app/models/status_broadcaster.rb`, and
`web/test/system/pipeline_flow_test.rb`. Confirmed that the status page now
opts the shared status-channel refresh signal into Turbo morph refresh with
scroll preservation, keeps the composer form `data-turbo-permanent` because
typed draft text and staged image chips live in browser state, and pins the
behavior with a Playwright system test that overflows the grid, scrolls down,
types into the composer, lands a live broadcast, and verifies scroll position
plus composer text survive.

Refreshed [[commands/web]] and [[testing]] so the status-grid scroll/composer
contract is documented alongside the existing Turbo Stream and task-page morph
coverage. Updated [[gaps]] so the hivebox residual entry includes `0dea8aa6`
and keeps the remaining uncertainty scoped to live Docker / long-running-agent
evidence against a deployed hivebox. Page coverage did not change, so
[[index]] did not need a catalog update. Did not run `qmd update` or
`qmd embed`.

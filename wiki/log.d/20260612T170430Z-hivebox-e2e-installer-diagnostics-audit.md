---
date: 2026-06-12
slug: hivebox-e2e-installer-diagnostics-audit
pages: [testing, gaps]
---

Post-commit wiki refresh after commit `03006e61` improved diagnostics for the
hivebox golden-path E2E daemon spawn and the Windows PowerShell installer
harness. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], and recent compiled [[log]] entries first. `qmd search "hivebox golden
path daemon env probe Windows installer file capture"` returned no indexed
hits; targeted `rg` over the configured master wiki found no Hivebox-specific
context.

Inspected the committed diff plus current `web/test/e2e/golden_path_e2e.rb`,
`packaging/docker/test-install-box.ps1`, `packaging/docker/install-box.ps1`,
`.github/workflows/ci.yml`, [[testing]], [[commands/web]], and the recent
golden-path / Windows-installer wiki fragments. Confirmed the source change is
test-harness diagnostic coverage, not a product behavior change:
`GoldenPathE2E#spawn_daemon!` now runs `bundle exec ruby -Ilib bin/hive
--version` with the exact daemon environment before `Process.spawn`, and the
failure teardown prints daemon stdout, PID liveness, and `$HIVE_HOME/logs`
inventory. `test-install-box.ps1` now redirects child installer output to a
temp file because `exit` inside `install-box.ps1` tears down piped PowerShell
capture before `Out-String` flushes.

Updated [[testing]] with the daemon-env preflight, expanded failure artifacts,
and file-backed PowerShell capture contract. Updated [[gaps]] to keep the
hivebox golden-path gap current: the workflow and diagnostics are pinned in
source/tests, but there is still no checked-in artifact proving a tagged
release CI pass, hosted installer availability, Windows Docker Desktop
end-to-end install, or full live Docker/provider first-run path. Page count did
not change, so [[index]] was not edited. Did not edit compiled [[log]], and did
not run `qmd update` or `qmd embed`.

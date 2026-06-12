---
date: 2026-06-12
slug: hivebox-bundler-installer-ci-audit
pages: [testing, gaps]
---

Post-commit wiki refresh after commit `6ff018e0` fixed the hivebox
golden-path E2E daemon's CI Bundler isolation and changed the Windows
PowerShell installer's failure copy from `Write-Error` to `Write-Host`. Read
`AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and
recent compiled [[log]] entries first. `qmd search "hivebox golden path bundler
BUNDLE_PATH Windows installer Write-Host"` returned no indexed hits, and
targeted `rg` over the configured master wiki found no Hivebox-specific
context.

Inspected the committed diff plus current `.github/workflows/ci.yml`,
`web/test/e2e/golden_path_e2e.rb`, `packaging/docker/install-box.ps1`,
`packaging/docker/test-install-box.ps1`, [[testing]], [[commands/web]], and the
recent hivebox E2E/installer wiki fragments. Confirmed the source change is
test/CI hardening, not a new product command surface: CI now installs the root
bundle into `vendor/root-bundle`, passes that path to the Rails E2E as
`GOLDEN_E2E_BUNDLE_PATH`, and `GoldenPathE2E#spawn_daemon!` pins
`BUNDLE_GEMFILE`, sets `BUNDLE_PATH`, and deletes inherited web-bundle
deployment/config keys before both the daemon env probe and foreground daemon
spawn. `install-box.ps1` now emits `Fail` messages with `Write-Host` so the
file-backed child-`pwsh` harness can capture friendly failure text before
`exit` unwinds the process.

Updated [[testing]] with the explicit root-bundle isolation and `Write-Host`
capture contract. Updated [[gaps]] so the hivebox golden-path install gap
includes `6ff018e0` while preserving the remaining uncertainty: no checked-in
artifact proves a tagged-release CI pass after this fix, hosted installer
availability, a Windows Docker Desktop end-to-end install, or the full live
Docker/provider first-run path. Page count did not change, so [[index]] was
not edited. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

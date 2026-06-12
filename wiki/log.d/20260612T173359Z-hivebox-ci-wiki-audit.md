---
date: 2026-06-12
slug: hivebox-ci-wiki-audit
pages: [testing, gaps, log]
---

Post-commit wiki refresh after commit `06674fcc` updated [[testing]],
[[gaps]], and added the prior hivebox Bundler/installer CI audit fragment.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "hivebox golden path
bundler installer Write-Host GOLDEN_E2E_BUNDLE_PATH"` returned no indexed hits;
targeted `rg` over the configured master wiki path and this checkout found only
the current hivebox CI/wiki references.

Inspected the committed diff for `06674fcc`, then re-checked the underlying
source commit `6ff018e0` and current `.github/workflows/ci.yml`,
`web/test/e2e/golden_path_e2e.rb`, `packaging/docker/install-box.ps1`, and
`packaging/docker/test-install-box.ps1`. Confirmed the wiki text matches the
source: the web CI job installs the root bundle into `vendor/root-bundle`,
passes it through `GOLDEN_E2E_BUNDLE_PATH`, the golden-path E2E pins the daemon
to the root `Gemfile` while clearing inherited web-bundle keys, and the
PowerShell installer emits failure copy with `Write-Host` so the file-backed
child-`pwsh` harness can capture it after `exit`.

No stale page content was found. [[testing]] and [[gaps]] already reflect the
current CI/test contracts and still preserve the remaining uncertainty about
tagged-release CI, hosted installer availability, Windows Docker Desktop, and
full live Docker/provider first-run evidence. Page coverage did not change, so
[[index]] was not edited. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

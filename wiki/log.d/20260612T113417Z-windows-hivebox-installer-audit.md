---
date: 2026-06-12
slug: windows-hivebox-installer-audit
pages: [index, commands, commands/web, gaps]
---

Post-commit command/API/executable/README coverage audit for `4c14bc3f`
(`feat(hivebox): Windows PowerShell installer`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
compiled [[log]] entries first. `qmd search "Windows PowerShell hivebox
installer install-box.ps1 Docker"` returned no indexed hits; targeted wiki and
configured master-wiki search found only the existing hivebox installer context.

Inspected the committed diff plus current `packaging/docker/install-box.ps1`,
`packaging/docker/install-box.sh`, `packaging/docker/README.md`, and
`.github/workflows/release.yml`. Confirmed the new PowerShell script matches
the shell installer contract: Docker availability/running checks, existing
container-name refusal, `HIVEBOX_IMAGE` / `HIVEBOX_NAME` / `HIVEBOX_PORT` /
`HIVEBOX_DATA` overrides, image pull, persistent `/data` mount, restart policy,
local URL printout, and first-login claim reminder. Refreshed [[index]],
[[commands]], and [[commands/web]] so the public install surface includes both
`https://hivecli.sh/box` and `https://hivecli.sh/box.ps1`; updated [[gaps]] to
record missing hosted-installer and Windows Docker Desktop live-smoke evidence.
Page count did not change. Did not edit compiled [[log]], run `qmd update`, or
run `qmd embed`.

---
date: 2026-06-12
slug: hivebox-image-ci-audit
pages: [commands/web, testing, gaps]
---

Post-commit wiki coverage audit for `4328b59a` (`ci(hivebox): test the image
on linux+mac, the installer on windows`). Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], recent compiled
[[log]] entries, and recent `wiki/log.d/` fragments first. `qmd search
"hivebox image CI installer Windows PowerShell smoke docker GitHub Actions"`
returned no indexed hits, and the configured master wiki path had no matching
Hivebox context.

Inspected the committed diff plus current `.github/workflows/ci.yml`,
`.github/workflows/release.yml`, `packaging/docker/smoke.sh`,
`packaging/docker/test-install-box.ps1`, `packaging/docker/install-box.sh`,
`packaging/docker/install-box.ps1`, `web/test/e2e/golden_path_e2e.rb`,
`test/e2e/tg/drive_idea.py`, [[commands/web]], [[testing]], and [[gaps]].
Refreshed [[testing]] and [[commands/web]] so they describe the new
workflow-pinned smoke matrix: Linux push/PR image boot smoke, release pre-push
amd64 smoke, post-publish macOS/Colima arm64 smoke, and Windows PowerShell
installer-script checks against stubbed Docker. Refined [[gaps]] rather than
closing it: the workflow code now pins the front-door image/installer checks,
but no checked-in artifact proves a successful tagged release run, hosted
`hivecli.sh` installer availability, Windows Docker Desktop end-to-end install,
or the full Docker path with real GitHub/gh/provider credentials. Page coverage
did not change, so [[index]] did not need a catalog update. Did not edit
compiled [[log]], run `qmd update`, or run `qmd embed`.

---
date: 2026-06-11
slug: hivebox-origin-audit
pages: [architecture, commands, commands/web, testing, gaps, index]
---

Post-commit audit for `8be458bd` (`fix(hivebox): normalize cloned repos to
https origins`). Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[architecture]], [[decisions]], [[gaps]], recent compiled [[log]] entries, and
the latest `wiki/log.d/` fragments first. `qmd search "hivebox https origin gh
auth git credential quarantine"` returned no indexed hits, and the configured
master wiki path had only generic command-injection guidance.

Inspected the committed diff plus current `web/app/controllers/repos_controller.rb`,
`web/config/routes.rb`, `web/test/integration/repos_test.rb`, and
`packaging/docker/Dockerfile`. Refreshed web command/API coverage so the Repos
surface now matches source: registration runs origin normalization after both
clone and existing-directory paths, leaves absent/non-GitHub remotes alone,
rewrites GitHub SSH origins to https, and relies on the Docker image's
`gh auth git-credential` helper for GitHub push auth. Refreshed [[testing]] for
the new Rails integration regression and recorded the remaining live-Docker
push smoke gap in [[gaps]]. Corrected [[index]] page-count/date metadata after
confirming the catalog already listed all 77 non-fragment wiki pages. Did not
run `qmd update` or `qmd embed`.

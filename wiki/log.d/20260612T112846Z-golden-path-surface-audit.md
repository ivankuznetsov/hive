---
date: 2026-06-12
slug: golden-path-surface-audit
pages: [index, architecture, decisions, commands, commands/web, modules/config, dependencies, testing, gaps]
---

Post-commit command/API/executable/README coverage audit for `bf3e7ee`
(`feat(hivebox): golden-path install — claim, same-origin, gh relay, image`).
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "hivebox golden path install claim same-origin gh relay docker image"`
returned no indexed hits, and the configured master wiki path had no matching
Hivebox context.

Inspected the committed diff plus current `lib/hive/web/github_auth.rb`,
`lib/hive/web/agents_auth.rb`, `web/app/controllers/sessions_controller.rb`,
`web/config/routes.rb`, `web/config/environments/production.rb`,
`packaging/docker/install-box.sh`, `packaging/docker/README.md`,
`packaging/docker/Dockerfile`, `.github/workflows/release.yml`, and the focused
web auth tests. Confirmed [[commands/web]] already documented the core web
surfaces, then refreshed adjacent coverage for the changed ownership/config
contract, `gh` relay dependency/API, same-origin Action Cable behavior,
GHCR/install-box release surface, and source-test evidence. Recorded remaining
uncertainty in [[gaps]]: no checked-in artifact proves the published GHCR image,
the hosted `hivecli.sh/box` installer, or a full live Docker first-run with
real GitHub/gh/repo push. Page count did not change. Did not edit compiled
[[log]], run `qmd update`, or run `qmd embed`.

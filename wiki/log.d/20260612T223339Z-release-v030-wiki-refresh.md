---
date: 2026-06-12
slug: release-v030-wiki-refresh
pages: [dependencies, operating, active-areas, gaps]
---

Post-commit command/API and README-surface wiki refresh after commit
`64b11b41` prepared release v0.3.0. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent compiled [[log]] entries first. `qmd search "release v0.3.0
hivebox README install version"` returned no indexed hits, and targeted search
of the configured master wiki path found no Hive-specific context.

Inspected the committed diff plus current `CHANGELOG.md`, `README.md`,
`install.md`, `lib/hive.rb`, `Gemfile.lock`, `packaging/docker/README.md`,
`docs/RELEASING.md`, [[commands]], [[commands/web]], [[dependencies]],
[[operating]], [[testing]], and [[active-areas]]. Confirmed the commit touches
release metadata and README/install snippets only: no Ruby routes, handlers,
Thor command handlers, executable entrypoints, or third-party dependency
versions changed. The lockfile diff changes only the local path gem from
`hive-cli (0.2.4)` to `hive-cli (0.3.0)`.

Updated [[dependencies]] for the current local path gem version, [[operating]]
for the current Linux installer and release-verification examples,
[[active-areas]] for the v0.3.0 release-prep row and current release/install
surface, and [[gaps]] to carry the remaining uncertainty: no checked-in artifact
was found proving `packaging/verify-release.sh --version=v0.3.0`, published
GitHub Release/Homebrew/AUR channel verification, or a published/smoke-passed
`ghcr.io/ivankuznetsov/hivebox:0.3.0` image after the tag exists. Page coverage
did not change, so [[index]] was not edited. Did not edit compiled [[log]], and
did not run `qmd update` or `qmd embed`.

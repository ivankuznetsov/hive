---
date: 2026-06-12
slug: dependency-rack-test-lockfile
pages: [dependencies, gaps, operating, active-areas]
---

Post-commit dependency coverage refresh after commit `2e307a19` touched
`Gemfile.lock`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[dependencies]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "rack-test dependency Gemfile.lock"` and
`qmd search "v0.2.4 release Gemfile.lock hive-cli"` returned no indexed hits;
the configured master wiki path only had general dependency notes, not
Hive-specific coverage.

Inspected the committed diff plus current `Gemfile`, `hive.gemspec`,
`Gemfile.lock`, `web/Gemfile`, and `web/Gemfile.lock`. Confirmed
`2e307a19` removes the stale root `rack-test` spec and top-level
`DEPENDENCIES` entry left after the root manifest removal in `b0a31edf`;
the separate web bundle still resolves `rack-test` transitively through
Rails/Capybara. Also inspected release commit `c7d8aa4f` because the current
root lockfile path gem is `hive-cli (0.2.4)`; that release diff changes only
the local path gem entry in `Gemfile.lock`, not third-party root dependency
constraints or resolved versions.

Updated [[dependencies]] for the resolved root `rack-test` lockfile state and
the current `hive-cli (0.2.4)` path-gem version. Updated [[gaps]] to close the
stale root `rack-test` uncertainty and carry the current unresolved
v0.2.4 release-channel verification gap. Updated [[operating]] and
[[active-areas]] release snippets that point at the current install/release
version. Page coverage did not change, so [[index]] was not edited. Did not
edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

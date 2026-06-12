---
date: 2026-06-11
slug: dependency-coverage-audit
pages: [dependencies, gaps]
---

Post-commit dependency coverage audit after the hivebox branch touched
dependency manifests. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[dependencies]], [[gaps]], and recent compiled [[log]] entries first.
`qmd search "dependency Gemfile Gemfile.lock web Gemfile Rails Redcarpet"`
returned no indexed hits; the configured master wiki only had general Rails
dependency patterns. Verified the latest dependency-touching commit
`d7ce55a9` (`web/Gemfile`, `web/Gemfile.lock`) plus the current root and web
manifests/lockfiles.

Confirmed Redcarpet is a web-bundle dependency only (`~> 3.6`, locked
3.6.1), added by `d7ce55a9` for sanitized markdown artifact rendering in
hivebox task pages. Refreshed [[dependencies]] so root dev/test coverage now
includes `rubocop-rails-omakase`, `brakeman`, and `bundler-audit`, and so the
web dev/test bundle and transitive `rack-test` use are covered. Recorded
uncertainty in [[gaps]]: commit `b0a31edf` removed the root `rack-test`
manifest declaration, but current `Gemfile.lock` still lists it as a
top-level dependency. Page coverage did not change, so [[index]] was not
edited. Did not run `qmd update` or `qmd embed`.

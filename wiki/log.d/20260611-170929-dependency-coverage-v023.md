## [2026-06-11T17:09:29Z] dependencies/wiki - refresh v0.2.3 lockfile coverage

**Action:** Refreshed dependency wiki coverage after commit `ad9b6204` touched
`Gemfile.lock` during the v0.2.3 release prep. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[dependencies]], [[gaps]], and recent
[[log]] / `wiki/log.d/` entries first; `qmd search "dependencies Gemfile.lock
hive-cli 0.2.3 release"` returned no indexed hits. Inspected the committed diff
plus current `Gemfile`, `hive.gemspec`, `Gemfile.lock`, `lib/hive.rb`, and
the existing v0.2.3 release/orphan-sweep wiki fragment.

Confirmed the committed dependency-file diff only changes the local path gem
entry from `hive-cli (0.2.2)` to `hive-cli (0.2.3)`, matching
`Hive::VERSION`; no third-party gem constraints or resolved third-party
versions changed in that commit. Updated [[dependencies]] because the manifest
ownership and counts were stale: runtime constraints live in `hive.gemspec`,
`Gemfile` pulls them through `gemspec`, direct runtime gems include
`faraday`/`faraday-multipart`, and the development/test table now lists
`rubocop-rails-omakase`, `brakeman`, and `bundler-audit`. Updated [[gaps]] to
make dependency-manifest coverage explicit and to carry the remaining
uncertainty that this source/lockfile refresh does not prove installed
v0.2.3 channel behavior. Updated [[index]] metadata only; page count stayed 76.
Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[dependencies]]
- [[gaps]]
- [[index]]

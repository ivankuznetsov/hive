## [2026-06-12T21:04:36Z] release/wiki — refresh v0.2.4 release coverage

**Action:** Refreshed release/install and dependency wiki coverage after commit `c7d8aa4f` tagged `v0.2.4`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], and recent [[log]] entries first. Searched the configured master wiki path `/home/asterio/wikis/master/wiki` plus the default cross-project paths; only the configured master path existed and it had no matching Hive-specific `v0.2.4` / Claude model-effort release guidance. `qmd search "claude model effort v0.2.4 patrol native reviewer release"` returned no results, so verification used direct git/source/wiki reads.

Inspected the clean working tree, recent git history, commit `c7d8aa4f`, and the then-current `lib/hive.rb`, `Gemfile.lock`, `CHANGELOG.md`, `README.md`, and `install.md`. Updated [[dependencies]] with a historical `hive-cli (0.2.4)` lockfile note and refreshed [[active-areas]] with v0.2.4 plus adjacent release/dependency rows. Current HEAD has since advanced to v0.3.0 through `8146d481`; [[operating]] and [[gaps]] already carry the current v0.3.0 install/release-verification examples and artifact-verification uncertainty from that later refresh. Page coverage did not change, so [[index]] needed no structural update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[dependencies]]

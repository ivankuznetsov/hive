## [2026-06-12T21:04:36Z] release/wiki — refresh v0.2.4 release coverage

**Action:** Refreshed release/install and dependency wiki coverage after commit `c7d8aa4f` tagged `v0.2.4`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], and recent [[log]] entries first. Searched the configured master wiki path `/home/asterio/wikis/master/wiki` plus the default cross-project paths; only the configured master path existed and it had no matching Hive-specific `v0.2.4` / Claude model-effort release guidance. `qmd search "claude model effort v0.2.4 patrol native reviewer release"` returned no results, so verification used direct git/source/wiki reads.

Inspected the clean working tree, recent git history, commit `c7d8aa4f`, and the current `lib/hive.rb`, `Gemfile.lock`, `CHANGELOG.md`, `README.md`, and `install.md`. Updated [[dependencies]] so the local path gem/version coverage points at `hive-cli (0.2.4)` and records that the lockfile change did not alter third-party dependencies. Updated [[operating]] install and release-verification snippets to `v0.2.4`, refreshed [[active-areas]] so the recent release table and release/install row reflect the current stable release, and updated [[gaps]] to carry the remaining uncertainty: no in-tree artifact proves `packaging/verify-release.sh --version=v0.2.4` or published Homebrew/AUR/GitHub Release channel verification after the tag exists. Page coverage did not change, so [[index]] needed no structural update. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[dependencies]]
- [[operating]]
- [[gaps]]

## [2026-06-24T17:28:41Z] wiki — refresh v0.3.1 release and workflow-engine coverage

**Action:** Refreshed high-level architecture, release/install, dependency, active-area, and gap coverage after commit `9efbca2a` prepared `0.3.1` and commit `9ca14ae0` updated the root dev/test bundle plus web fixture task creation. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], and recent compiled [[log]] entries first. Searched the configured exact `main_wiki_path` (`/home/asterio/wikis/master/wiki`) and checked the default cross-project wiki paths; only the configured master path existed, and the search found no Hive-specific release/workflow guidance beyond a generic debt-tracker index hit. `qmd search "hive custom workflow 0.3.1 release install changelog"` surfaced older release-wiki history, so verification used the clean working tree, recent git history, the top release-prep diff, and direct reads of `README.md`, `CHANGELOG.md`, `docs/RELEASING.md`, `install.md`, `lib/hive.rb`, `Gemfile.lock`, `web/Gemfile.lock`, `Gemfile`, and affected wiki pages.

Documented that the current checkout is `0.3.1`, both root and web lockfiles pin `hive-cli (0.3.1)`, the public installer snippets now point at `v0.3.1`, and `docs/RELEASING.md`'s release-prep summary explicitly requires syncing both lockfiles because hivebox depends on the gem through `path: ".."`. Updated the project overview language to match the README's agent workflow engine/meta-harness positioning and to foreground descriptor-backed custom workflows, `hive workflow new --template`, and `hive init --new-workflow`. Recorded the remaining uncertainty: no in-tree artifact proves `packaging/verify-release.sh --version=v0.3.1`, a published `v0.3.1` GitHub Release, Homebrew/AUR updates, or a `ghcr.io/ivankuznetsov/hivebox:0.3.1` image. Page count stayed 84, so [[index]] needed only metadata/summary refresh, not a page-list change. Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[index]]
- [[commands/workflow]]
- [[dependencies]]
- [[operating]]
- [[active-areas]]
- [[gaps]]

## [2026-06-11T18:26:30Z] wiki — refresh JSON wrapper last-flag coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `56f1fdcb` changed `bin/hive`, `bin/hive-e2e`, and focused wrapper tests so wrapper-owned usage/error formatting consults the last recognized JSON boolean flag instead of any truthy flag. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "JSON wrapper boolean error mode false flags"` surfaced existing wrapper coverage, and the configured master wiki path had no relevant matching pattern. Inspected the committed diff plus current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, `test/e2e/lib/hive_e2e_binary_test.rb`, [[cli]], [[commands]], [[e2e]], [[testing]], and [[gaps]]. Updated the affected pages to document that duplicate JSON boolean flags are resolved by the final recognized boolean for wrapper-owned usage/preflight/error output, so final false forms like `--no-json` or `--json=false` force prose even after an earlier `--json`. The existing packaged-wrapper uncertainty remains: no in-tree artifact proves the RubyGems/Homebrew/AUR-installed `hive` executable exercises this wrapper path. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[e2e]]
- [[testing]]
- [[gaps]]

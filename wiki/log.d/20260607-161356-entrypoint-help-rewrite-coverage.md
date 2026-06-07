## [2026-06-07T16:13:56Z] wiki — audit entrypoint help rewrite coverage fragment

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after this branch changed `bin/hive` and `bin/hive-e2e` help rewriting. Read `AGENTS.md`, `.llm-wiki/config.json`, [[cli]], [[commands]], [[e2e]], [[testing]], and [[gaps]] first; `qmd search "bin hive-e2e --version command-local help wrapper"` returned no local hits, while the configured master wiki search surfaced the existing Hive CLI/e2e/testing pages. Inspected the rebased diff and current `bin/hive`, `bin/hive-e2e`, `test/integration/cli_version_test.rb`, and `test/e2e/lib/hive_e2e_binary_test.rb`. Confirmed existing [[cli]], [[commands]], [[e2e]], [[testing]], and [[gaps]] coverage matches the code: command-local help now preserves any leading wrapper options before the subcommand, rewrites to `help <cmd>`, and drops command arguments after the subcommand so option-bearing requests such as `hive approve --from 2-brainstorm --help` and `bin/hive-e2e run --filter tui --help` print usage instead of running partial command validation. [[gaps]] records the remaining uncertainty that the packaged `hive` executable has not been release-install-smoked for this path; `bin/hive-e2e` remains checkout-only. Page coverage did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[e2e]]
- [[testing]]
- [[gaps]]

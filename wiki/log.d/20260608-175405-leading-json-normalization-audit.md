## [2026-06-08T17:54:05Z] wiki — audit leading JSON option normalization

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `53ab6187` fixed `bin/hive` so leading truthy JSON class-option forms are normalized before Thor dispatch. The committed diff changed `bin/hive` and `test/integration/cli_usage_error_json_test.rb`: `truthy_json_option?` now recognizes `--json`, `--json=true`, `--json=1`, and `--json=yes`; `normalize_leading_json_options!` canonicalizes those leading forms to command-local `--json`; and the usage-error JSON test now pins `hive --json=true run` to the `hive-run` error envelope with exit 64.

Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first. `qmd search "leading --json=true run usage error envelope bin hive"` found the existing [[cli]] and [[gaps]] context; the configured master wiki path had no matching prior pattern. Inspected the committed diff plus current `bin/hive`, `lib/hive/cli.rb`, `test/integration/cli_usage_error_json_test.rb`, [[cli]], [[commands]], [[testing]], and [[gaps]]. Updated the wiki to document leading JSON normalization, the narrow pre-dispatch JSON usage-error contract, and the focused integration test. Page coverage did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[testing]]
- [[gaps]]

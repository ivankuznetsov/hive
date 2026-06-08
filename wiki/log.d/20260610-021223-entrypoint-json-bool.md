## [2026-06-10T02:12:23Z] cli - refresh JSON boolean entrypoint coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after the PR changed `bin/hive` and `test/integration/cli_version_test.rb`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "command api surface routes handlers commands executable entrypoints README"` surfaced existing command/API refresh history, and the configured master wiki path added only generic route/command guidance. Inspected the committed diff plus current `bin/hive`, `lib/hive/cli.rb`, `lib/hive/commands/patrol.rb`, `test/integration/cli_version_test.rb`, [[cli]], [[commands]], [[commands/patrol]], and [[testing]]. Documented that `bin/hive` now normalizes leading exact JSON boolean spellings (`--json=true`, `--json=t`, plus uppercase variants, and explicit false forms) before Thor dispatch, and rejects unsupported valued forms such as `--json=1` / `--json=yes` with usage exit 64 before a missing target can be reported. The patrol engine and `hive-patrol.v1` payload did not change; this was a wrapper/entrypoint contract refresh. Page coverage did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[testing]]
- [[gaps]]

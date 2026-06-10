## [2026-06-10T13:09:08Z] wiki — audit CLI JSON usage-envelope coverage

**Action:** Refreshed command/API and executable-entrypoint wiki coverage after commit `b03260a2` changed `bin/hive`'s pre-dispatch Thor usage-error handling. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "JSON usage errors command envelopes bin hive wrapper"` surfaced existing CLI/testing coverage, and the configured master wiki path had no relevant project-specific context. Inspected the committed diff plus current `bin/hive`, `lib/hive/cli.rb`, schema registrations in `lib/hive.rb`, `test/integration/cli_usage_error_json_test.rb`, [[cli]], [[commands]], and [[testing]]. Updated [[commands]] to document the wrapper-level schema map, tightened [[cli]] to distinguish mapped pre-dispatch usage errors from command-local rescue paths, clarified the representative integration-test coverage in [[testing]], and updated [[gaps]] to carry forward the missing release-installed wrapper smoke evidence. Page coverage count did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands]]
- [[cli]]
- [[testing]]
- [[gaps]]

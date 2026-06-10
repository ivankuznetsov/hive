## [2026-06-10T13:17:26Z] wiki — audit residual CLI JSON envelope coverage

**Action:** Audited residual wiki commit `c9a688c7` after it changed [[cli]], [[commands]], [[testing]], [[gaps]], and added the prior CLI JSON usage-envelope audit fragment, then incorporated follow-up source commit `18f93a1d`. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "JSON usage errors command envelopes bin hive wrapper"` surfaced the existing CLI/testing coverage, and the configured master wiki path had no matching project-specific context. Inspected the residual committed diff, the underlying source commit `b03260a2`, follow-up commit `18f93a1d`, and relevant source in `bin/hive`, `lib/hive/workflows.rb`, `lib/hive/cli.rb`, `lib/hive.rb`, and `test/integration/cli_usage_error_json_test.rb`. Refreshed [[cli]] and [[commands]] to record that workflow-verb pre-dispatch JSON-envelope mapping is derived from `Hive::Workflows::VERBS`, refreshed [[testing]] for the broader wrapper-map integration coverage, and carried forward the release-installed wrapper smoke gap in [[gaps]]. Page coverage count did not change, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[cli]]
- [[commands]]
- [[testing]]
- [[gaps]]

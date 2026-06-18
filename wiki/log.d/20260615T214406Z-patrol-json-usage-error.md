---
date: 2026-06-15
slug: patrol-json-usage-error
pages: [testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`25082ee4` changed `bin/hive` and
`test/integration/cli_usage_error_json_test.rb`. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]],
and recent [[log]] entries first. `qmd search "patrol json missing argument
errors prose only required argument command usage"` surfaced the existing
wrapper-contract coverage in [[cli]], [[testing]], and [[gaps]]; the configured
master wiki path had no Hive-specific patrol usage-error guidance.

Inspected the committed diff plus current `bin/hive`,
`test/integration/cli_usage_error_json_test.rb`, [[cli]], [[commands]],
[[commands/patrol]], [[testing]], and [[gaps]]. Confirmed `bin/hive` now
includes `patrol` in `JSON_USAGE_ERROR_CONTRACTS`, so `hive patrol --json`
with no `PROJECT` exits 64 and emits a `hive-patrol` error envelope with
`error_kind: "error"` instead of only prose stderr. The focused integration
test now pins that schema, schema version, `InvalidTaskPath` class, and usage
exit code.

Updated [[testing]] to name the patrol-specific wrapper regression and
refreshed [[gaps]] to cite the current split between the broad
`36f7499a` wrapper mapping and the `25082ee4` patrol fix while preserving the
remaining release-install uncertainty. Page coverage did not change, so
[[index]] was not edited. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

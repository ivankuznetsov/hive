---
date: 2026-06-18
slug: patrol-json-coverage-followup
pages: [commands/patrol, gaps]
---

Post-commit wiki refresh after commit `239b93c6` updated patrol JSON wiki
coverage and recorded a schema/test uncertainty. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "patrol JSON usage error
similar_to_existing skipped_findings hive-patrol"` returned no indexed
matches, and the configured master wiki path had no matching patrol/schema
guidance.

Inspected the committed diff plus current `bin/hive`,
`lib/hive/commands/patrol.rb`, `lib/hive/patrol/fingerprint.rb`,
`schemas/hive-patrol.v1.json`, `test/integration/cli_usage_error_json_test.rb`,
`test/integration/patrol_command_test.rb`, `test/unit/schema_files_test.rb`,
[[commands/patrol]], [[modules/patrol]], [[cli]], [[testing]], and [[gaps]].
Confirmed the pre-dispatch `hive patrol --json` missing-`PROJECT` envelope is
covered in source/tests/wiki, and confirmed the remaining schema/test gap is
real: source can emit `skipped_findings[].reason = "similar_to_existing"`,
while the v1 schema enum and focused schema payload test do not cover that
reason.

Refreshed [[commands/patrol]] so the step list and JSON reason text mention the
similar-known skip explicitly, and refreshed [[gaps]] with the 2026-06-18
recheck. Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

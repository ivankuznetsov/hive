---
date: 2026-06-15
slug: patrol-json-coverage-audit
pages: [commands/patrol, gaps]
---

Post-commit wiki coverage audit after commit `77579ae1` committed residual
wiki changes for the `25082ee4` patrol JSON usage-error fix. Read `AGENTS.md`,
`.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent
[[log]] entries first. `qmd search "patrol JSON usage error required argument
hive-patrol"` found the current wrapper-contract coverage in [[testing]],
[[cli]], [[gaps]], and [[log]]; the configured master wiki path had no
Hive-specific patrol usage-error guidance.

Inspected the committed diff, source commit `25082ee4`, current `bin/hive`,
`lib/hive/cli.rb`, `lib/hive/commands/patrol.rb`,
`test/integration/cli_usage_error_json_test.rb`,
`test/integration/patrol_command_test.rb`, `test/unit/schema_files_test.rb`,
`schemas/hive-patrol.v1.json`, [[cli]], [[commands]], [[commands/patrol]],
[[testing]], and [[gaps]]. Confirmed the committed [[testing]] and [[gaps]]
refresh describes the `hive patrol --json` missing-`PROJECT` pre-dispatch
envelope. Refreshed [[commands/patrol]] to document that pre-dispatch
`hive-patrol` error payload and to name the current skipped-finding reason
surface.

Recorded a remaining schema/test uncertainty in [[gaps]]: patrol source can
emit `skipped_findings[].reason = "similar_to_existing"`, but
`schemas/hive-patrol.v1.json` and the focused schema validation test do not
cover that reason yet. Page coverage did not change, so [[index]] was not
edited. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

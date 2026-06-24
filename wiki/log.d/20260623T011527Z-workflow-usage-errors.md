## workflow - bare subcommand usage errors

**Action:** Routed bare `hive workflow` through the command body instead of
Thor's required-argument check. The command now emits
`hive workflow: missing SUBCOMMAND (expected: new)` in human mode and a
`hive-workflow-new` usage envelope with `expected: ["new"]` in JSON mode; the
unknown-subcommand envelope keeps `value` and also reports `expected`.

**Tests:** Added focused command coverage and wrapper integration coverage for
bare human/JSON usage errors, unknown JSON extras, and published schema
validation for the new `expected` field.

**Pages:** [[commands/workflow]]

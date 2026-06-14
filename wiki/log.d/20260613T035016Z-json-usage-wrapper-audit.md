---
date: 2026-06-13
slug: json-usage-wrapper-audit
pages: [cli, commands, testing, gaps]
---

Post-commit command/API and executable-entrypoint wiki refresh after commit
`b4eeeeb3` changed `bin/hive` and `test/integration/cli_version_test.rb`.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]],
[[decisions]], [[gaps]], and recent compiled [[log]] entries first. `qmd search
"command API surface routes handlers commands executable entrypoints README"`
surfaced prior wrapper-contract refreshes; the configured master wiki path had
only generic route/coverage guidance, so verification used the committed diff
plus direct source reads.

Inspected the commit diff and current `bin/hive`,
`test/integration/cli_version_test.rb`,
`test/integration/cli_usage_error_json_test.rb`, `lib/hive.rb`,
`lib/hive/cli.rb`, `lib/hive/commands/rebase_status.rb`, [[cli]],
[[commands]], [[commands/rebase-status]], [[commands/patrol]], [[testing]], and
[[gaps]]. Confirmed the executable wrapper now maps pre-dispatch Thor usage
errors for required-argument commands through `JSON_USAGE_ERROR_CONTRACTS`:
versioned schemas use `Hive::Schemas::ErrorEnvelope`, workflow verbs carry the
`verb` extra, finding toggles carry `operation`, `patrol` reports
`error_kind: "error"`, and the older `hive-rebase-status` inspector keeps its
unversioned sibling JSON shape.

Updated [[cli]] and [[commands]] for the wrapper-level usage-error JSON mapping,
[[testing]] for the focused checkout coverage, and [[gaps]] to carry the
remaining uncertainty: no checked-in artifact proves the packaged
RubyGems/Homebrew/AUR `hive` executable exercises the expanded wrapper path.
Page coverage did not change, so [[index]] was not edited. Did not edit
compiled [[log]], and did not run `qmd update` or `qmd embed`.

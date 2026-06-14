---
date: 2026-06-14
slug: json-usage-wrapper-residual-audit
pages: [commands/stage_action, gaps]
---

Post-commit command/API and executable-entrypoint wiki audit after the rebased
head `2b0d651f` only added the prior wrapper audit fragment for the
`bin/hive` JSON usage-error work. Read `AGENTS.md`, `.llm-wiki/config.json`,
[[index]], [[architecture]], [[decisions]], [[gaps]], and recent compiled
[[log]] entries first. `qmd search "command API surface routes handlers
commands executable entrypoints README wiki coverage"` surfaced earlier wrapper
and command/API refreshes; the configured master wiki had only generic route
coverage guidance, so verification used the committed diff plus direct source
reads.

Inspected `HEAD`, the preceding residual wiki commit `66c470cd`, and the
rebased source commit `8b31acd6`, plus current `bin/hive`, `lib/hive/cli.rb`,
`lib/hive.rb`, `lib/hive/commands/rebase_status.rb`,
`lib/hive/commands/stage_action.rb`,
`test/integration/cli_version_test.rb`,
`test/integration/cli_usage_error_json_test.rb`, [[cli]], [[commands]],
[[commands/rebase-status]], [[commands/patrol]], [[commands/stage_action]],
[[testing]], and [[gaps]]. Confirmed [[cli]], [[commands]], and [[testing]]
already cover `JSON_USAGE_ERROR_CONTRACTS`: required-argument failures for
workflow verbs, `run`, `approve`, `drop`, `findings`, `markers`,
`rebase-status`, and `patrol` emit command-shaped JSON when `--json` is present;
registered schemas use `Hive::Schemas::ErrorEnvelope`, while
`hive-rebase-status` intentionally remains unregistered and unversioned.

Refreshed [[commands/stage_action]] because its examples still described the
current workflow-verb JSON contract as `schema_version: 1`; the producer now
uses `Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-stage-action")`, which is
version 2, and the current schema file is `schemas/hive-stage-action.v2.json`.
Updated [[gaps]] to cite the rebased source commit `8b31acd6` for the wrapper
usage-error expansion while preserving the unresolved uncertainty: no in-tree
artifact proves a packaged RubyGems/Homebrew/AUR `hive` executable exercises
the expanded wrapper path. Page coverage did not change, so [[index]] did not
need a page-list update. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

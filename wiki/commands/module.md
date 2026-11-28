---
title: hive module
type: command
source: lib/hive/cli.rb, lib/hive/commands/module.rb, lib/hive/commands/module/*.rb, schemas/hive-module-*.v1.json
created: 2026-09-02
updated: 2026-09-02
tags: [command, modules, honeycomb, lifecycle, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-module) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive module` previews, applies, inspects, diagnoses, and evaluates
reviewed project-local modules. Lifecycle mutations are receipt-bound and
consent-gated; list, status, inspect, doctor, and dry-run are read-only.

## Behavior

`install`, `update`, `enable`, `disable`, and `uninstall` first produce a
preview bound to current and candidate generations, configuration, hook
choices, bindings, and grants. Non-interactive apply requires `--yes`, the
exact unexpired receipt, and every required choice. Changed catalog state,
selection, or permissions invalidates the receipt before mutation.

`list`, `status`, `inspect`, and `doctor` consume the shared redacted module
projection. They never expose secret values, raw environment, unsafe stderr,
or unbounded logs. `doctor` diagnoses but does not repair. Module `dry-run`
uses the pure trigger evaluator and writes nothing; it is distinct from the
legacy behavior of `hive patrol --dry-run`.

## Tests

`test/unit/commands/module_command_test.rb`, the sibling module command tests,
and `test/integration/module_cli_usage_test.rb` cover dispatch, lifecycle and
read-only output, consent, redaction, and usage envelopes.

## Backlinks

- [[cli]] · [[modules/workflow_package]] · [[modules/attempts]]

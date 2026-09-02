---
title: hive module
type: command
source: lib/hive/cli.rb, lib/hive/commands/module.rb, lib/hive/commands/module/*.rb, schemas/hive-module-*.v1.json
created: 2026-09-02
updated: 2026-09-02
tags: [command, modules, honeycomb, lifecycle, json]
---

**TLDR**: `hive module` previews, applies, inspects, diagnoses, and evaluates
reviewed project-local modules. Lifecycle mutations are receipt-bound and
consent-gated; list, status, inspect, doctor, and dry-run are read-only.

## Usage

```bash
hive module install honeycomb/NAME[@VERSION] --dry-run --json [OPTIONS]
hive module update NAME --dry-run --json [OPTIONS]
hive module enable NAME --dry-run --json
hive module disable NAME --dry-run --json
hive module uninstall NAME --dry-run --json
hive module list [--json]
hive module status [NAME] [--json]
hive module inspect NAME [--json]
hive module doctor NAME [--json]
hive module dry-run NAME --event EVENT [--schedule CRON] [--occurred-at TIME] [--json]
```

Apply a reviewed lifecycle preview by repeating its choices with `--yes` and
the exact `--receipt RECEIPT` value.

## Options

- `--dry-run` builds a no-write lifecycle preview; for the `dry-run`
  subcommand it evaluates one supplied event without writes.
- `--yes` consents to a freshly revalidated lifecycle mutation.
- `--receipt VALUE` binds an apply to the matching preview.
- Repeatable `--setting NAME=VALUE`, `--hook ID=enabled|disabled`, and
  `--grant CATEGORY=VALUE` provide explicit installation choices.
- Legacy Honeycomb compatibility accepts repeatable `--mapping` and
  `--input-binding` values plus `--allow-escalation`.
- Event evaluation accepts `--event`, `--schedule`, and `--occurred-at`.
- `--json` selects the subcommand-specific v1 envelope.

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

## Output and schemas

Every JSON contract is version 1:

| Subcommand | Schema |
|---|---|
| `install`, `update`, `enable`, `disable`, `uninstall` | `hive-module-lifecycle.v1` |
| `list` | `hive-module-list.v1` |
| `inspect`, `status` | `hive-module-status.v1` |
| `doctor` | `hive-module-doctor.v1` |
| `dry-run` | `hive-module-dry-run.v1` |

Success documents carry `ok: true` and the operation's redacted projection or
preview. Error documents carry `ok: false`, `error_class`, `error_kind`,
`exit_code`, and `message`. Missing/unknown subcommands and positional-shape
errors use `hive-module-lifecycle.v1` with `error_kind: usage`.

## Error and serialization policy

Lifecycle errors distinguish consent, ownership, concurrent-run, catalog,
configuration, Git, and general failures. Each delegated Hive error preserves
its typed exit code. Module output uses direct `JSON.generate`; there is no
module-specific generator-failure suppression, so a serialization failure
raises instead of substituting a second document.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Inspection, preview, evaluation, or mutation succeeded. |
| 64 | Missing/unknown subcommand, missing subject, extra positional, or another usage error. |
| 1 | Unclassified system or I/O failure. |
| Other | The exact delegated `Hive::Error#exit_code`, also present in a JSON error envelope. |

## Examples

```bash
hive module list --json
hive module status --json
hive module install honeycomb/example --dry-run --json \
  --setting REGION=eu --hook nightly=enabled --grant network=api.example.test
hive module install honeycomb/example --yes --receipt RECEIPT \
  --setting REGION=eu --hook nightly=enabled --grant network=api.example.test
hive module dry-run example --event schedule --schedule '*/10 * * * *' --json
```

## Tests

`test/unit/commands/module_command_test.rb`, the sibling module command tests,
and `test/integration/module_cli_usage_test.rb` cover dispatch, lifecycle and
read-only output, consent, redaction, and usage envelopes.

## Backlinks

- [[cli]] · [[modules/workflow_package]] · [[modules/attempts]]

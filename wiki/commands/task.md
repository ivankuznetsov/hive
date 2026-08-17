---
title: hive task
type: command
source: lib/hive/cli.rb, lib/hive/commands/task.rb, lib/hive/task_workspace/builder.rb, schemas/hive-task-workspace.v2.json
created: 2026-08-16
updated: 2026-08-16
tags: [command, task, semantic, workspace, json, diagnosis]
---

**TLDR**: `hive task TARGET --project NAME --json` resolves one exact
registered task and emits the same bounded `hive-task-workspace` v2 semantic
document used by normal Hive Web task HTML. It is the native agent inspection
surface for the task's canonical headline/action, workflow result and primary
artifact, applicable evidence, exactly attributed usage, API-equivalent price
coverage, and receipt-correlated diagnostic-log reference. It is read-only and
does not expand fleet `hive status --json`.
`hive task TARGET --project NAME --log` re-resolves a current diagnostic and
prints only its integrity-checked bounded receipt-correlated tail.

## Synopsis

```bash
hive task TARGET [--project NAME] [--json | --log]
```

`TARGET` follows `Hive::TaskResolver`: an exact path, globally unique slug, or
task ID. Use `--project` for a bare slug or ID whenever more than one registered
project could match. The command checks ordinary canonical status first and
then the archive projection for that exact stage, so a retained archived task
remains inspectable and is marked read-only.

Without `--json`, the command prints a compact human summary: headline, action,
primary-result reference, and usage coverage. `--json` is the stable machine
surface and emits one schema-valid `hive-task-workspace` v2 document.
`--log` is a read-only diagnostic surface and cannot be combined with `--json`.
It fails closed when the semantic diagnostic is not current, the receipt
reference changed, its digest/size is invalid, or the bounded file is absent.

## Meaning and boundaries

The command instantiates `Hive::TaskWorkspace::Builder#semantic` directly. It
therefore shares Web's meaning instead of scraping HTML or maintaining a
CLI-only result model:

- `headline` and `action` come from fresh canonical task status. Optional
  usage, price, publication, or diagnostic evidence cannot manufacture an
  action or disable an otherwise fresh canonical one.
- `result` and `applicability` come from the normalized workflow result
  contract. A declared final document is primary when present; the current
  stage artifact is the in-progress fallback.
- `usage` counts exact durable session bindings once across failures and
  retries. Harness, actual provider/model, and billing route remain separate.
  API-equivalent USD includes coverage and missing dimensions.
- `diagnostic.log.reference` is the current attempt receipt's bounded
  `log_reference` when a genuine error/recovery state exists. Use the same
  target with `--log` for deep diagnosis; Hive re-resolves the reference and
  reads it through one no-follow descriptor. Do not open its path or select a
  log by newest-file mtime.

The document is local, deterministic, bounded, redacted, credential-free, and
mutation-token-free. It contains neither raw logs nor attempt/provenance/
lifecycle chronology. Strict v1 audit JSON remains at the authenticated Web
task `.json` route, and raw timeline pages remain authenticated Web resources.

This task view is not a provider probe or billing statement. Do not infer live
provider health, quota, credential validity, actual invoice spend, or
provider-observed billing from it. Use `hive status --operational --json` for
current workflow/scheduler ownership and `hive circuits inspect --json` for
the dedicated provider-account/model health projection.

## Tests

- `test/integration/task_command_test.rb`
- `test/unit/task_workspace/schema_test.rb`
- `test/unit/task_workspace/builder_test.rb`
- `test/unit/task_workspace/usage_test.rb`
- `test/unit/task_workspace/correlated_log_test.rb`
- `web/test/integration/tasks_test.rb`

## Backlinks

- [[cli]] · [[commands]] · [[commands/status]] · [[commands/web]]
- [[modules/task_workspace]] · [[modules/workflows]] · [[token-usage]]

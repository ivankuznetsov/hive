---
title: hive task
type: command
source: lib/hive/cli.rb, lib/hive/commands/task.rb, lib/hive/task_workspace/builder.rb, schemas/hive-task-workspace.v2.json
created: 2026-08-16
updated: 2026-11-07
tags: [command, task, semantic, workspace, json, diagnosis]
---

**TLDR**: `hive task TARGET --project NAME --json` resolves one exact
registered task and emits the same bounded `hive-task-workspace` v2 semantic
document used by normal Hive Web task HTML. It is the native agent inspection
surface for the task's canonical headline/action, workflow result and primary
artifact, applicable evidence, exactly attributed usage, API-equivalent price
coverage, and receipt-correlated diagnostic-log reference. It is read-only and
does not expand the former fleet-wide status graph.
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

The exact project projection owns one read-only attempts-store scope through
action and receipt-bound diagnostic annotation. It does not require a
fleet-status caller to have opened that scope first.

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
provider usability, quota, credential validity, actual invoice spend, or
provider-observed billing from it. Use `hive status --operational --json` for
current workflow and scheduler ownership. Provider routing is recomputed from
current configuration and live attempt capacity; there is no health projection.

## Remote API projection

With a remote context, `hive task TASK --project PROJECT --context NAME`
resolves only that server project and task. `PROJECT:TASK` is also explicit
project-qualified addressing. It never derives a local project from cwd or
accepts a checkout path. Remote JSON uses the API envelope below.

The remote content selectors are mutually exclusive:

```sh
hive task TASK --project PROJECT --context NAME --log
hive task TASK --project PROJECT --context NAME --diff
hive task TASK --project PROJECT --context NAME --artifacts --json
hive task TASK --project PROJECT --context NAME --artifact RESOURCE_ID --output ./answer.md
```

Without `--output`, requested content goes to stdout. `--output` names an
explicit client destination; server paths never become client targets. The new
`--diff`, `--artifacts` and `--artifact ID` selectors fail under default or
explicit local context before effects, with guidance to use the existing local
`hive task --json` artifact panel or a remote context. Local `--log` still cannot
be combined with `--json`; remote `--log --json` returns one API document.

The bearer-authenticated `/api/v1/projects/:project/tasks/:task` reader accepts
an exact registered project plus a task ID or slug. It returns a deliberately
smaller DTO in the `hive-remote.v1` envelope, with native schema/version named
as `source_schema`/`source_schema_version` provenance. It does not claim the
partial DTO conforms to the full native workspace schema. Filesystem paths,
raw command suggestions and cross-project dependency details are excluded.
Action descriptors require the matching token scopes; forced transitions stay
local. `approval_generation` identifies the current ownership generation for
an explicit approval, separately from the native semantic task generation.

Related read routes expose questions, correlated logs, owned-worktree diffs,
and workflow-declared artifacts. Questions carry opaque server-issued handles;
the native folder-bearing answer binding remains in an owner-only server
registry. Artifact IDs and status continuation cursors are also opaque and
bound to their authorized targets and current observations. Unknown or
cross-target IDs return 404; known stale observations return 409 and require
refreshing the inventory. Read identities survive a server restart and confer
no mutation admission authority.

Status pages contain at most 100 tasks and 2 MiB, with counts computed over the
authorized projects before pagination. Logs are limited to 256 KiB; selected
artifact and diff responses to 512 KiB, including the escaped JSON envelope.
Smaller `max_bytes` limits are accepted; a limit too small for control metadata
returns 413. A truncated response says so explicitly. Artifact manifests retain
the native 20-file/2-MiB aggregate limits and never use client-supplied paths.

## Serialization and exit codes

The semantic document is encoded directly. A `JSON::GeneratorError` is not
replaced with prose or a fallback JSON document; it propagates.

| Code | Meaning |
|---:|---|
| 0 | The semantic document, human summary, or correlated log tail was emitted. |
| 1 | Current correlated diagnostic evidence was missing or failed integrity validation. |
| 64 | The target was missing/ambiguous or `--log` was combined with `--json`. |
| 78 | Project, workflow, or global configuration was invalid. |

## Examples

`hive task demo:checkout --json` emits the bounded semantic workspace; use
`hive task checkout --project demo --log` for the correlated diagnostic tail.

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

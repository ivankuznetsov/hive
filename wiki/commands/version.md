---
title: hive version
type: command
source: bin/hive, lib/hive/cli.rb, lib/hive/runtime_identity.rb, schemas/hive-version.v1.json
created: 2026-09-02
updated: 2026-09-02
tags: [command, version, runtime, json]
---

**TLDR**: `hive version` reports the release version; JSON mode additionally
identifies the active runtime channel, display version, build SHA, and
deployment.

## Usage

```bash
hive version [--json]
hive --version
hive -v
```

## Options and aliases

- `hive version --json` emits the versioned machine contract.
- Exact top-level `--version` and `-v` invocations are wrapper aliases that
  print the release semantic version as text and exit before Thor dispatch.

No other command-specific options apply.

## Behavior

Human output is `Hive::VERSION` followed by a newline. JSON output captures
`Hive::RuntimeIdentity`, allowing dogfood and installed releases to share the
same release semantic version while exposing their actual loaded build and
deployment identity.

## Output and schema

`hive version --json` emits `hive-version.v1` with `ok: true` and a `runtime`
object containing `channel`, `release_version`, `display_version`, `build_sha`,
and `deployment_id`. Exact top-level `--version` and `-v` aliases are text-only.

## Error and serialization policy

The JSON payload contains only registry/version and normalized runtime identity
values and is serialized directly with `JSON.generate`. No command-specific
fallback document or generator-error suppression applies.

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Version text or the v1 JSON document emitted. |
| 70 | An unexpected internal failure prevents version reporting. |

## Examples

```bash
hive version
hive version --json
hive --version
```

## Tests

`test/unit/cli_test.rb` covers release text, dogfood runtime identity, and
validation against `hive-version.v1`; wrapper tests cover `--version` and `-v`.

## Backlinks

- [[cli]] · [[operating]] · [[release-candidate]]

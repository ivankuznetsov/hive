---
title: hive forget
type: command
source: lib/hive/commands/forget.rb
created: 2026-05-06
updated: 2026-05-22
tags: [command, registry, cleanup, json]
---

**TLDR**: `hive forget NAME [--json]` removes the entry whose `name` matches NAME from the global registry (`~/Dev/hive/config.yml`). Inverse of `hive init`. The project's `.hive-state` directory on disk is **not** touched — registry and on-disk state are intentionally independent. Unknown name is a USAGE error (exit 64); empty NAME positional is a distinct USAGE error with `error_kind: "missing_name"`. Bulk version: [[commands/prune]].

## Usage

```
hive forget NAME            # remove one named entry; text output
hive forget NAME --json     # same, machine-readable envelope
```

## Why

The global registry accumulates entries forever. `mktemp -d`-style test runs leave stale `(missing)` rows that no surface used to clean up — only `hive init` ever wrote to `registered_projects`. `hive forget` is the inverse: drop one named entry without touching the project's on-disk state, even if the path is gone.

For the bulk-of-stale-entries case, prefer `hive prune`. The TUI grid Shift+X key now drops the focused task via [[commands/drop]]; registry cleanup stays on the shell surfaces `hive forget` and `hive prune`.

## Steps performed (`Hive::Commands::Forget#call`)

1. Validate `$HIVE_HOME`. If explicitly set to a non-existent directory, raise `Hive::ConfigError` (exit 78). Without this gate a typoed env var used to surface as `unknown_project` (exit 64), masking the real cause.
2. Validate NAME positional. Empty/whitespace → `error_kind: "missing_name"` / exit 64.
3. Resolve via `Hive::Config.unregister_project(name:)`. Returns the removed Hash entry or nil.
4. nil → `error_kind: "unknown_project"` / exit 64 (mirrors `hive metrics --project NAME`).
5. Otherwise: rewrite `config.yml` and emit success.

## JSON contract (`schema = "hive-forget"`, version 1)

### Success

```json
{
  "schema": "hive-forget",
  "schema_version": 1,
  "ok": true,
  "name": "demo",
  "path": "/home/me/Dev/demo",
  "hive_state_path": "/home/me/Dev/demo/.hive-state"
}
```

### Error envelope

```json
{
  "schema": "hive-forget",
  "schema_version": 1,
  "ok": false,
  "error_class": "UsageError",
  "error_kind": "unknown_project",
  "exit_code": 64,
  "message": "hive forget: no entry named \"ghost\" in /home/me/Dev/hive/config.yml"
}
```

`error_kind` enum (closed, mirrors `Hive::Schemas::ForgetErrorKind::ALL`):

| `error_kind` | Exit | Cause |
|---|---|---|
| `missing_name` | 64 | NAME positional was empty/whitespace |
| `unknown_project` | 64 | NAME does not match any registry entry |
| `config` | 78 | malformed `config.yml` or missing `$HIVE_HOME` |
| `internal` | 70 | uncategorised crash |

External consumers validate against `schemas/hive-forget.v1.json`; resolve via `Hive::Schemas.schema_path("hive-forget")`.

## Idempotency

`hive forget X` is **not** retry-idempotent today: a second invocation after a successful drop returns `unknown_project` / exit 64, indistinguishable from a typo. Agent retry wrappers must handle this themselves until a future `--if-exists` flag or `already_forgotten` error_kind lands.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/prune]] · [[commands/tui]]
- [[modules/config]] — `Hive::Config.unregister_project` is the underlying primitive

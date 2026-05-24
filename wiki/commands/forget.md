---
title: hive forget
type: command
source: lib/hive/commands/forget.rb
created: 2026-05-06
updated: 2026-05-06
tags: [command, registry, cleanup, json]
---

**TLDR**: `hive forget NAME [--json] [--if-exists]` removes the entry whose `name` matches NAME from the global registry (`~/Dev/hive/config.yml`). Inverse of `hive init`. The project's `.hive-state` directory on disk is **not** touched — registry and on-disk state are intentionally independent. Unknown name is normally a USAGE error (exit 64), but `--if-exists` makes an already-absent entry exit 0 with `removed: false`; empty NAME positional is a distinct USAGE error with `error_kind: "missing_name"`. Bulk version: [[commands/prune]].

## Usage

```
hive forget NAME              # remove one named entry; text output
hive forget NAME --json       # same, machine-readable envelope
hive forget NAME --if-exists  # retry-safe: exit 0 if NAME is already absent
```

## Why

The global registry accumulates entries forever. `mktemp -d`-style test runs leave stale `(missing)` rows that no surface used to clean up — only `hive init` ever wrote to `registered_projects`. `hive forget` is the inverse: drop one named entry without touching the project's on-disk state, even if the path is gone.

For the bulk-of-stale-entries case, prefer `hive prune`. The TUI grid `X` keystroke is gated to `error: "missing_project_path"` rows only; for any other unhealthy state (`not_initialised`, etc.) the TUI's refusal flash points at `hive forget`.

## Steps performed (`Hive::Commands::Forget#call`)

1. Validate `$HIVE_HOME`. If explicitly set to a non-existent directory, raise `Hive::ConfigError` (exit 78). Without this gate a typoed env var used to surface as `unknown_project` (exit 64), masking the real cause.
2. Validate NAME positional. Empty/whitespace → `error_kind: "missing_name"` / exit 64.
3. Resolve via `Hive::Config.unregister_project(name:)`. Returns the removed Hash entry or nil.
4. nil → with `--if-exists`, emit success (`removed: false`) and exit 0; otherwise `error_kind: "unknown_project"` / exit 64 (mirrors `hive metrics --project NAME`).
5. Otherwise: rewrite `config.yml` and emit success.

## JSON contract (`schema = "hive-forget"`, version 1)

### Success

```json
{
  "schema": "hive-forget",
  "schema_version": 1,
  "ok": true,
  "removed": true,
  "name": "demo",
  "path": "/home/me/Dev/demo",
  "hive_state_path": "/home/me/Dev/demo/.hive-state"
}
```

With `--if-exists`, an already-absent entry succeeds without path fields:

```json
{
  "schema": "hive-forget",
  "schema_version": 1,
  "ok": true,
  "name": "demo",
  "removed": false
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

`hive forget X --if-exists` is retry-idempotent: a second invocation after a successful drop exits 0 and reports `removed: false`. Without `--if-exists`, `hive forget X` preserves the strict typo-detection behavior: unknown names return `unknown_project` / exit 64.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/prune]] · [[commands/tui]]
- [[modules/config]] — `Hive::Config.unregister_project` is the underlying primitive

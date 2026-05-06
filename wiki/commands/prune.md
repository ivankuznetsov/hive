---
title: hive prune
type: command
source: lib/hive/commands/prune.rb
created: 2026-05-06
updated: 2026-05-06
tags: [command, registry, cleanup, json]
---

**TLDR**: `hive prune [--dry-run] [--json]` drops every registry entry in `~/Dev/hive/config.yml` whose `path` no longer points at a directory on disk **or** whose row shape is invalid (non-Hash, missing `path`, non-String name/path — all hand-edit accidents). The project's `.hive-state` directory on disk (when present) is **not** touched. Bulk version of [[commands/forget]] for the common-case `mktemp -d`-style stale-entry pile-up.

## Usage

```
hive prune                  # text output, rewrites config.yml
hive prune --dry-run        # show what would be dropped, do not write
hive prune --json           # machine-readable envelope
hive prune --dry-run --json # both
```

## Why

After running `hive init` against tmpfs paths (test, dogfooding), the directories vanish but the registry entries do not. The TUI's project list keeps showing them as `(missing)`. `hive prune` is the bulk-cleanup verb. Same envelope shape on `--dry-run` so an agent can preview the drop set before executing.

Malformed rows from a hand-edited `config.yml` (e.g., a non-Hash entry or a row missing `path`) used to brick every hive command via the loader. The loader now silently skips them; `hive prune` operates below the loader and reports them as droppable so the cleanup path is complete.

## Steps performed (`Hive::Commands::Prune#call`)

1. Validate `$HIVE_HOME`. Typoed env var → `Hive::ConfigError` (exit 78).
2. Read `config.yml`. Malformed YAML → `Hive::ConfigError` (exit 78). Missing file → empty result.
3. Partition entries: drop rows where the shape is invalid OR `File.directory?(path)` is false.
4. With `--dry-run`: return `{removed:, kept_count:}` without writing.
5. Without `--dry-run`: rewrite `config.yml` with the kept rows.

## JSON contract (`schema = "hive-prune"`, version 1)

### Success

```json
{
  "schema": "hive-prune",
  "schema_version": 1,
  "ok": true,
  "dry_run": false,
  "removed": [
    {"name": "stale", "path": "/tmp/gone", "hive_state_path": "/tmp/gone/.hive-state"}
  ],
  "removed_count": 1,
  "kept_count": 3
}
```

### Error envelope

```json
{
  "schema": "hive-prune",
  "schema_version": 1,
  "ok": false,
  "error_class": "ConfigError",
  "error_kind": "config",
  "exit_code": 78,
  "message": "global config at /home/me/Dev/hive/config.yml is not valid YAML: ..."
}
```

`error_kind` enum (closed, mirrors `Hive::Schemas::PruneErrorKind::ALL`):

| `error_kind` | Exit | Cause |
|---|---|---|
| `usage` | 64 | reserved for future flag-validation; pre-declared so v1 absorbs it without a v2 bump |
| `config` | 78 | malformed `config.yml` or missing `$HIVE_HOME` |
| `internal` | 70 | uncategorised crash |

External consumers validate against `schemas/hive-prune.v1.json`; resolve via `Hive::Schemas.schema_path("hive-prune")`.

## Symlink semantics

`File.directory?` follows symlinks. A registered path that is a symlink to a deleted target reports as missing; a stale symlink that gets relinked to any directory survives prune. The "is the original directory really there?" question requires `realpath` resolution, which is **not** done today — see open follow-up.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/forget]] · [[commands/tui]]
- [[modules/config]] — `Hive::Config.prune_missing_projects!` is the underlying primitive

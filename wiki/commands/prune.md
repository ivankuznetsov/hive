---
title: hive prune
type: command
source: lib/hive/commands/prune.rb
created: 2026-05-06
updated: 2026-09-02
tags: [command, registry, cleanup, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-prune) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive prune [--dry-run] [--json]` drops every registry entry in `~/Dev/hive/config.yml` whose `path` no longer points at a directory on disk, whose stored `real_path` no longer matches the current target, **or** whose row shape is invalid (non-Hash, missing `path`, non-String name/path — all hand-edit accidents). The project's `.hive-state` directory on disk (when present) is **not** touched. Bulk version of [[commands/forget]] for the common-case `mktemp -d`-style stale-entry pile-up.

## Why

After running `hive init` against tmpfs paths (test, dogfooding), the directories vanish but the registry entries do not. The TUI's project list keeps showing them as `(missing)`. `hive prune` is the bulk-cleanup verb. Same envelope shape on `--dry-run` so an agent can preview the drop set before executing.

Malformed rows from a hand-edited `config.yml` (e.g., a non-Hash entry or a row missing `path`) used to brick every hive command via the loader. The loader now silently skips them; `hive prune` operates below the loader and reports them as droppable so the cleanup path is complete.

## Steps performed (`Hive::Commands::Prune#call`)

1. Validate `$HIVE_HOME`. Typoed env var → `Hive::ConfigError` (exit 78).
2. Read `config.yml`. Malformed YAML → `Hive::ConfigError` (exit 78). Missing file → empty result.
3. Partition entries: drop rows where the shape is invalid, `File.directory?(path)` is false, or a stored `real_path` no longer matches the current target of that path.
4. With `--dry-run`: return `{removed:, kept_count:}` without writing.
5. Without `--dry-run`: rewrite `config.yml` with the kept rows.

## Symlink semantics

`register_project` stores a private `real_path` when the registered path can be resolved. `prune` still treats a broken symlink as missing through `File.directory?`, and now also drops a symlink entry when the current `File.realpath(path)` differs from the stored `real_path`. Legacy or hand-written rows without a valid absolute-string `real_path` keep the old path-existence behavior until they are re-registered.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/forget]] · [[commands/tui]]
- [[modules/config]] — `Hive::Config.prune_missing_projects!` is the underlying primitive

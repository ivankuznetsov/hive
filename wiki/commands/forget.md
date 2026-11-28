---
title: hive forget
type: command
source: lib/hive/commands/forget.rb
created: 2026-05-06
updated: 2026-09-02
tags: [command, registry, cleanup, json]
---

> **Public CLI authority:** See [docs/cli.md](../../docs/cli.md#hive-forget) for canonical invocation syntax, options, JSON schemas, context rules, and exit codes. This page documents internal implementation, storage, and architecture.

**TLDR**: `hive forget NAME [--if-exists] [--json]` removes the entry whose `name` matches NAME from the global registry (`~/.config/hive/config.yml` by default, or `HIVE_HOME/config.yml` when overridden). Inverse of `hive init`. The project's `.hive-state` directory on disk is **not** touched — registry and on-disk state are intentionally independent. Unknown name is a USAGE error (exit 64) unless `--if-exists` is passed; empty NAME positional is a distinct USAGE error with `error_kind: "missing_name"`. Bulk version: [[commands/prune]].

## Why

The global registry accumulates entries forever. `mktemp -d`-style test runs leave stale `(missing)` rows that no surface used to clean up — only `hive init` ever wrote to `registered_projects`. `hive forget` is the inverse: drop one named entry without touching the project's on-disk state, even if the path is gone.

For the bulk-of-stale-entries case, prefer `hive prune`. The TUI grid Shift+X key now drops the focused task via [[commands/drop]]; registry cleanup stays on the shell surfaces `hive forget` and `hive prune`.

## Steps performed (`Hive::Commands::Forget#call`)

1. Validate `$HIVE_HOME`. If explicitly set to a non-existent directory, raise `Hive::ConfigError` (exit 78). Without this gate a typoed env var used to surface as `unknown_project` (exit 64), masking the real cause.
2. Validate NAME positional. Empty/whitespace → `error_kind: "missing_name"` / exit 64.
3. Resolve via `Hive::Config.unregister_project(name:)`. Returns the removed Hash entry or nil.
4. nil without `--if-exists` → `error_kind: "unknown_project"` / exit 64 (mirrors `hive metrics --project NAME`).
5. nil with `--if-exists` → success with `removed: false`; the registry is not rewritten.
6. Otherwise: rewrite `config.yml` and emit success with `removed: true`.

## Idempotency

`hive forget X` remains strict by default: a second invocation after a successful drop returns `unknown_project` / exit 64, preserving typo detection for humans. Retry wrappers should call `hive forget X --if-exists`; that path exits 0 for both "removed a row" and "already absent" and distinguishes the two cases in JSON via `removed: true | false`.

## Backlinks

- [[cli]] · [[commands/init]] · [[commands/prune]] · [[commands/tui]]
- [[modules/config]] — `Hive::Config.unregister_project` is the underlying primitive

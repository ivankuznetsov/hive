---
title: Historical state conversion
type: command
source: docs/guides/current-format-migration.md
updated: 2026-09-09
tags: [migration, current-format]
---

`hive migrate` has been removed. Hive supports only its current formats.
For older installations, use the [agent migration guide](../../docs/guides/current-format-migration.md)
with verified backups and an explicit inventory. Startup and update never import,
seal, rename, backfill, or repair historical state automatically.

A healthy current database is retained unchanged. Fresh setup creates the current
database; unsupported existing databases are refused. Task folders outside current
workflows remain visible in status with `legacy_state_guide` so they cannot silently
disappear. Current managed workflow installation/update remains supported.

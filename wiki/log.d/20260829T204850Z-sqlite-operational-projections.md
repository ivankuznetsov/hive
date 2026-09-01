---
title: Usage and daemon observations joined the runtime control plane
date: 2026-08-29
tags: [runtime-control-plane, sqlite, usage, daemon, status, attempts]
---

`Hive::UsageDb` now uses Sequel datasets over the shared runtime control plane
and no longer owns a SQLite schema, migration path, environment override, or
standalone database. Usage reads preserve unavailable-versus-zero behavior;
authoritative persistence failures remain typed and fail closed.
Standalone Patrol launches retain idempotent session identity but stay
attempt-unattributed, so telemetry never fabricates an Attempts foreign key.

Daemon scheduler observations and complete status projections now publish as
one source-bound database generation. CLI, Web, TUI, and metrics readers reject
missing, stale, corrupt, or mismatched rows without consulting the retired
snapshot or status-cache files. Terminal finalization also waits for durable
task-journal acknowledgement before downstream accounting, provider-health,
delivery, or promotion work begins.

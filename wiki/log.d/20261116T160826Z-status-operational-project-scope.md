---
title: hive status --operational honors --project
type: fix
created: 2026-11-16
updated: 2026-11-16
tags: [status, operational, cli, json, schema]
---

`hive status --operational --project hivedev` used to ignore `--project`
without a warning and print every registered project. Operators and agents
naturally use `--project` to narrow the view, so the ignored filter misled
them.

- `--operational --project NAME` now scopes both the text view and `--json`
  to that registered project. An unknown name raises `Hive::UsageError`
  `unknown project "NAME" (registered: ...)`, and a blank name raises
  `--project must not be empty`. Both exit 64 before any scheduler, cache, or
  task read.
- The daemon status-cache lookup and any fresh scan still cover every
  registered project. Only the projection narrows:
  `Hive::OperationalStatus.new(project_scope:)` builds tasks, summary,
  archive, issues, completeness, scheduler/daemon applicability, and
  `recovery_rows` from that project's graph entry. Cache reuse is unchanged,
  and a row blocked by `other:slug` keeps that reason.
- `hive-operational-status.v5` gains an additive optional
  `scope: { "project": NAME }`, present only on a scoped view. The schema
  version is not bumped. The human heading appends ` · project NAME`.
- `--project` help now lists `--operational`.
- Plain `hive status --project` and `hive archive --project` listing still
  ignore the filter; see [[gaps]] and [[commands/status]].

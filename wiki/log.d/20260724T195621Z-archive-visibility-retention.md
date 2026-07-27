---
title: Workflow archive visibility retention
date: 2026-07-24
tags: [workflows, archive, retention, status, tui, web, daemon]
---

# Workflow archive visibility retention

Workflow descriptors now declare `archive_visibility_retention_days` as a
positive integer or exact lowercase `never`; legacy omission resolves to three
days. Hive-owned built-ins and workflow scaffolds declare `3` explicitly, and
descriptor/default/pin edits reproject on the next normal refresh.

The first successful workflow-aware archive transition records an immutable UTC
`completed_at`. A bounded, lock-aware legacy backfill prefers the first credible
completion event, then terminal state-file and task-folder mtimes. Only a
durably committed clock can hide a row; failures warn and keep it visible.

One shared projection now supplies ordinary CLI/status JSON,
operational/daemon snapshots, TUI, native web, and Hivebox. Ordinary payloads
add only `hidden_archived_task_count`; task objects stay unchanged. Dedicated
CLI, TUI, and web archive views remain unfiltered and workflow-aware.

See [[modules/workflows]], [[commands/status]], [[commands/tui]],
[[commands/web]], [[modules/daemon]], [[state-model]], and [[testing]].

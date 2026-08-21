---
title: Harden Patrol Fix review and recovery boundaries
type: change
date: 2026-08-21
tags: [patrol, architecture-patrol, patrol-fix, daemon, migration, observability]
---

- Kept transient UsageDb seed failures out of the durable ambiguity state, so
  discovery retries after telemetry recovers instead of parking until midnight.
- Made daemon admission registry-fresh and isolated a corrupt source outbox to
  one bounded failed event while later projects and engines continue draining.
- Made legacy ordinary migration snapshots deterministic when old findings have
  no lifecycle timestamp, and added an empty-stdin forward resume that reads the
  controller-owned durable migration manifest after the effect boundary.
- Added fresh nonce delimiters to semantic-admission prompts and routed the
  integrated lifecycle through the production approval transition instead of a
  test-owned filesystem move.
- Rendered the common Patrol capacity, workflow, migration, and delivery state
  in scoped TUI, Telegram status, and the web Patrol overview.

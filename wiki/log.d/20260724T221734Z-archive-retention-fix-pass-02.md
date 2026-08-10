---
title: Archive retention review fix pass 02
date: 2026-07-24
tags: [archive, retention, completed-at, status, tui]
---

- Made terminal run and approve mutations roll back filesystem, metadata, and
  index state symmetrically, and reject malformed completion clocks.
- Preserved archive membership across policy repins and used the membership
  workflow for legacy history discovery.
- Made legacy backfill deadline-bounded, restart-fair, generation-consistent,
  and isolated from unrelated staged hive-state changes.
- Captured all project workflow/config generations before status scanning and
  made TUI hidden-pin and wall-clock retention changes converge on the next
  normal poll.

---
title: Archive-aware status refreshes now scale with active work
date: 2026-07-27
---

- `StateSource` now keeps authoritative visible archive rows separately and
  reparses only workflow-active stage directories on steady liveness ticks.
- TUI mode retains a complete archive cache with a 30-second repair backstop.
  Hive Web reuses the same source in visible-only mode, uses a five-minute
  backstop, and leaves complete `/archive` reads on demand.
- Status supplies a private workflow-aware archive-folder index during the
  authoritative ordinary scan. StateSource consumes and removes that field
  before publication, avoiding a second web scan without changing the public
  `hive-status` schema.
- Archive-cache publication is generation-fenced so an older background scan
  cannot overwrite a newer policy, terminal-membership, or retention
  projection.
- The 8-project by 200-task scale fixture passed the TUI scaling gate. On the
  loaded development host, the web adapter measured a 17.48 ms median idle
  refresh and 177.11 ms median active reparse; the private index did not leak.

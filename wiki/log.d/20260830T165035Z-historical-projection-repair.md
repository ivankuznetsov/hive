---
title: Repair journal-less historical task projections
date: 2026-08-30
---

- Fixed `hive repair-projection` so the exact command advertised for a
  pre-projection historical task can establish a bounded marker-derived
  checkpoint when the journal, snapshot, and checkpoint are all absent.
- Kept durable execute handoffs and any partial or malformed projection
  authority fail-closed; repair does not invent an authoritative journal.
- Added integration coverage for a historical `9-done` task and a regression
  proving that a missing durable-handoff journal remains unrecoverable.

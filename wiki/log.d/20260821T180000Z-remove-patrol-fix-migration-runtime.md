---
title: Remove Patrol Fix runtime migration
type: change
date: 2026-08-21
---

- Removed the Patrol Fix migration controller, cutover state, source epochs,
  migration adapters, schemas, CLI actions, and operational status section.
- Accepted findings now reserve immutable source snapshots directly in the
  Patrol Fix admission store.
- `script/migrate_patrol_findings.rb` is the sole one-time path for historical
  ordinary findings and creates normal `patrol-fix` tasks without GitHub work.
- Ordinary Patrol no longer exposes dead local patch/report directories or the
  old PR and dismissal ledger reconciliation API.
- Dry-run finding lifecycle transitions remain in memory and do not mutate the
  authoritative Patrol store.

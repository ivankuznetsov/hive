---
title: Remove Patrol Fix runtime migration
type: change
date: 2026-08-21
---

- Removed the Patrol Fix migration controller, cutover state, source epochs,
  migration adapters, schemas, CLI actions, and operational status section.
- Accepted findings now enter source outboxes directly.
- `script/migrate_patrol_findings.rb` is the sole one-time path for historical
  ordinary findings and creates normal `patrol-fix` tasks without GitHub work.

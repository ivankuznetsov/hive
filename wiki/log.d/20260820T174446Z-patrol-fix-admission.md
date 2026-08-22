---
title: Durable Patrol fix admission and task capture
date: 2026-08-20
---

- Added source-owned, default-disabled handoff outboxes for accepted ordinary
  and Architecture Patrol records.
- Added one source-neutral admission scheduler with exact-first and
  digest-revalidated semantic admission, provider retry parking, and no
  dependency on discovery cadence or allowance.
- Extracted idempotent task capture from `hive new`; Patrol materialization now
  persists intent before creation, binds task and evidence before source
  acknowledgement, and repairs interrupted create or provenance-update steps.
- Expanded the Patrol Fix component boundary to cover the admission core while
  retaining one-way source adapters and an inert cutover gate.

---
title: Cut runtime dispatch and provider coordination over to SQLite
date: 2026-08-29
tags: [sqlite, dispatch, admission, provider-health, pr-merge]
---

- Made `AdmissionTransition` the sole short immediate transaction for request
  claim, authoritative source/generation recheck, capacity and route
  validation, probe ownership, attempt creation, accounting, lineage, and
  routing-decision persistence.
- Replaced dispatch request/result files and provider circuit journals with
  Sequel repositories over the shared runtime control plane. Recovery,
  idempotency, audit, terminal delivery, and operational projections now use
  bounded typed SQL rows.
- Replaced the serialized PR merge reconciliation document with typed
  task/generation/revision-fenced candidate rows and bounded SQL selection;
  JSON remains evidence payload rather than control authority.
- Deleted superseded queue-directory, replay, compaction, preclaim-file, and
  malformed-file protocols. Bot, Web, daemon, and recovery now share the SQL
  repositories; `hive circuits` retains list/inspect/block/unblock/reset while
  removed file-quarantine repair options move to control-plane recovery.

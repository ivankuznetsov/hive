---
title: Replace JobStore conversion with an opaque explicit fresh start
type: change
created: 2026-07-30
tags: [architecture-patrol, jobstore, reset, recovery, storage]
---

- Removed the v2 JobStore reader/converter, restore path, installation and
  all-user coordinators, privileged identity discovery, package hooks, system
  retry services, compatibility schemas, and their test gates.
- Added one explicit `hive refactor-patrol-reset PROJECT --confirm` boundary.
  It binds one registered project, holds the stable profile activation lock,
  drains and proves the current daemon generation plus its supervised writers
  stopped, takes the existing Patrol effect lock exclusively, repeats an
  independent PID/start-time fence, and never runs automatically.
- The reset atomically exchanges only the released `v2/jobs` directory with a
  canonical regular marker. Its exact opaque bytes survive under a
  transaction-bound hidden archive; Hive never enumerates or imports them.
  Every other v2 owner and the global terminal-proof catalog remain in place.
- A completed transaction admits an empty v3 JobStore and stores its receipt
  outside both generations. Interrupted exchange resumes idempotently, while
  non-empty v3 state, malformed evidence, live writers, or unavailable atomic
  exchange fail closed.
- A daemon stopped by reset is restarted only after the new exact generation
  publishes operational runtime readiness. The reset command emits one
  schema-validated success or typed error JSON envelope for automation.
- Daemon JSON status now reports `fresh`, `current`, `reset_required`,
  `reset_incomplete`, `conflict`, or isolated `error` per registered project
  without performing the reset, moving a legacy registry, or cleaning update
  state temporary files.

---
title: Harden project workflow degradation boundaries
type: change
source: lib/hive/workflows/project.rb, lib/hive/daemon/dispatcher.rb, lib/hive/daily_digest/project_source.rb, web/app/models/task.rb
created: 2026-10-14
---

- Same-root nested configuration validation now keeps an outer fallback
  workflow view instead of mistaking the configured directory for a deliberate
  nested switch.
- Managed package resolution no longer holds the process-wide Project Monitor
  while waiting for the package mutation lock.
- Daemon, digest, board, and task best-effort readers contain typed activation
  failures; public digest gaps redact configuration details, and unavailable Web
  workflows suppress stage mutation affordances.
- Workflow union readers rely on their already-frozen return values, stage-filter
  diagnostics use a deterministic union vocabulary, and the executable reader
  inventory drives its negative controls through the production assertion.

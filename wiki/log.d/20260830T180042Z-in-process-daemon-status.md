---
title: Produce daemon status graphs in-process
date: 2026-08-30
---

- Replaced the daemon's per-scan `hive status --internal-task-graph --json`
  child process with a direct object boundary to the existing status producer.
- Removed daemon-only subprocess, JSON parsing, and schema-skew compatibility
  machinery while retaining exact-envelope and bounded-task validation.
- Preserved direct and nested workflow/task projection warnings through an
  in-process warning sink, including breadcrumbs emitted before a failed scan.
  The bot's separate hidden status transport is unchanged.
- Extended daemon source-drift detection to fingerprint the now-resident status
  producer as well as schema identity.
- Switched daemon workflow E2Es from their retired CLI/JSON mapper shim to the
  production in-process `StatusConsumer`.

---
date: 2026-07-22
slug: rails-resource-mutations
---

- Removed the web-only `Hive::Web::Dispatcher` orchestration layer. Filesystem-backed Rails resources now own their behavior: task mutations enter `Task`, idea capture enters `Project`, and daemon liveness/repair enters `Daemon`.
- Kept the canonical Hive commands, daemon queue, guarded recovery sequence, and brainstorm writer as the mechanics beneath those resources; controllers now load one resource, invoke one domain method, and choose an HTTP response.
- Made daemon repair a conventional resource `create` action while preserving `POST /daemon/repair` and its queue contract. Task lookup now distinguishes a degraded project snapshot from a genuinely missing task, preserving actionable operator errors instead of returning a false 404. Added model and integration coverage for stale submissions, custom workflows, recovery sidecar cleanup, queue failures, brainstorm writes, idea capture, and daemon repair.
- Updated [[architecture]], [[commands/web]], [[commands/drop]], [[commands]], [[testing]], and [[gaps]] for the Rails resource boundary.

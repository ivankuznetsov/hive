---
title: Audit queued branch contracts against current wiki
date: 2026-07-22T13:37:15Z
tags: [wiki, attempts, conditions, web, daemon, workflows, patrol, digest]
---

- Inspected every queued immutable source SHA with `git show` and inspected
  representative branch-tree blobs with `git show <sha>:<path>` across native
  Hive web, durable attempt reconciliation/loss, coherent operational status,
  task condition journals and policy, managed workflow runtime policy, Kanban
  actions, and patrol budgets. Also checked the configured master wiki for
  cross-project context. QMD was intentionally not run.
- Confirmed the current project wiki already has equal or richer coverage for
  the queued behavior: [[commands/web]], [[modules/attempts]],
  [[modules/conditions]], [[modules/daemon]], [[modules/workflows]],
  [[commands/refactor-patrol]], [[commands/digest]], [[state-model]], and
  [[testing]] cover the resulting command, architecture, data-model, recovery,
  and verification contracts. The v0.6.6 dependency/release snapshot is also
  already present. No new page or index change was warranted.
- Updated [[gaps]] with the branch-only/duplicate provenance boundary and the
  stale `067171bf` path entry: the advertised Hivebox OAuth-relay note is not
  in that commit; the actual Hive-web note and Rails sources are authoritative.

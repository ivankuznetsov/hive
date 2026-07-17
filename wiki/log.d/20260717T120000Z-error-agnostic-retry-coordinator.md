---
title: One error-agnostic retry coordinator
date: 2026-07-17
tags: [daemon, retries, attempts, journal, status, recovery]
---

- Bound task-stage retry policy to the durable attempt ownership and
  generation-scoped task-journal/projection primitives landed by #9767/#9768;
  no attempt/generation sidecar or parallel identity was introduced.
- Added the one class-agnostic schedule (`60, 60, 60, 300, 600, 3600`, final
  value repeated forever), absolute restart-safe deadlines, idempotent terminal
  reporting, fenced successor authorization, and audited repair/abandon/re-arm.
- Demoted stale/recoverable healers and provider signals to observation,
  evidence, and wakeup roles; removed task retry quarantine, local budgets,
  marker-clear reruns, probes-before-deadline, and alternate dispatch authority.
- Added the canonical terminal-error/evidence registry and current-daemon
  environment inheritance without persisting environment maps or secrets.
- Published the optional exact status-v4 `retry` projection through CLI, TUI,
  web, bot, and dispatcher, plus the generation-guarded `hive retry` operator
  actions.
- Added unit, integration, contract, schema/correspondence, and tagged incident
  replay coverage. Startup reconciliation sends observed terminal legacy/dead
  attempts through the same idempotent reporter; legacy in-memory counts and
  quarantine are intentionally not migrated.

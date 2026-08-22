---
title: Patrol fix task artifacts and projection
date: 2026-08-20
---

- Registered the first-party `patrol-fix` workflow with visible inbox, fix,
  validate, review, publish, and receipt-gated done stages.
- Added strict task-local source manifests, append-only generation-bound
  receipts, and one bounded projection consumed by status, operational status,
  task workspace, TUI, and bot surfaces.
- Parked semantic outcomes remain non-runnable and can only be reopened through
  the common project-scoped, generation-guarded operational action.

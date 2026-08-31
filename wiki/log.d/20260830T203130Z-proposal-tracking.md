---
title: Add skill and workflow proposal history
date: 2026-08-30
---

- Added immutable project-level skill/workflow candidate records, independent
  evaluation and lifecycle events, durable task-bound source receipts,
  idempotent reconciliation, quotas, and logical per-input quarantine.
- Added dispatch-admitted evaluator identity and separately configured
  decision/supersession/rollback authority with lifecycle-head plus considered
  evaluation compare-and-swap.
- Added live proposal CLI discovery and actions, deterministic pinned JSON and
  Markdown wiki compilation, provider-free proposal-only refresh, and bounded
  typed-facts-only prompt context.
- Kept pre-feature projects proposal-empty during read-only discovery: Hive
  never imports historical task journals, and the first newly admitted typed
  source event initializes the ledger lazily.
- Kept the complete subsystem tracking-only: no acceptance, supersession,
  rollback, compile, query, or context operation activates or changes an active
  skill or workflow.

---
title: Stage the Workflow Creator Values candidate
type: change
created: 2026-08-03
tags: [architecture, component-boundaries, workflow-creator, values]
---

- Added the dependency-free
  `HiveLiveAgentProof::WorkflowCreator::Values` leaf. Capture imports exact
  JSON-shaped Ruby values through load-captured core operations into an
  anonymous, non-copyable, non-marshalable, recursively frozen snapshot and
  emits owned canonical UTF-8 bytes.
- Added focused hostile-value proof for caller hooks, post-load core
  replacement, mutation, cycles, encodings, key collisions, numeric forms,
  resource ceilings, canonical-byte properties, and the exact R43
  line/callable/decision and per-method budgets.
- Kept dependency proof local to the leaf: `Ripper.lex` rejects bare and
  qualified `require` and `require_relative` identifiers while ignoring
  comments and strings, and a direct
  `ruby --disable-gems -I<repository-root>` subprocess proves clean loading.
  No generic Ruby/path analyzer or component-loader behavior was added.
- Added one values-only `candidate` catalog row with no consumers,
  dependencies, or production activation and exactly one
  `removal_unit: U1a1vt` fence. The shared validator changed only to admit
  that exact empty-consumer shape and hierarchical removal-unit identifiers.
- `U1A1VI-ARCH-003` is disposed by removing the misplaced generic analyzer
  responsibility. The aggregate `U1A1V-R02-ARCH-002` finding remains
  program-open for U1a1vt; this change does not claim generic require-path
  canonicalization, boundary readiness, publication, or live behavior.

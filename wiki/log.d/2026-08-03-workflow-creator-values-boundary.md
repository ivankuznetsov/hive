---
title: Stage the Workflow Creator Values boundary
type: change
created: 2026-08-03
tags: [architecture, component-boundaries, workflow-creator, values]
---

- Added the dependency-free `HiveLiveAgentProof::WorkflowCreator::Values`
  candidate entry point for exact JSON-shaped core values. Capture produces an
  anonymous frozen snapshot with a recursively owned value graph and compact,
  sorted-key canonical UTF-8 bytes ending in one newline.
- Made admission fail closed through one fixed secret-free error for unsupported
  types, invalid encodings, cycles, duplicate normalized keys, non-finite
  floats, and exact depth, node, source-byte, canonical-byte, logical-work, and
  integer-bit limits.
- Sealed the public core traversal operations used by capture so caller hooks
  and post-load monkeypatches cannot intercept import. Pre-load core mutation
  and concurrent caller mutation remain explicit non-goals.
- Used owned-hash length changes for expected-constant-time normalized-key
  collision admission, leaving only the separately charged canonical sort.
  Captured allocation, initialization, and raise operations keep fixed,
  distinct capture and Marshal failures intact after post-load replacement of
  `Kernel#raise` or `Exception#initialize`; frozen private prototypes remain a
  diagnostic invariant rather than the behavioral proof.
- Added focused behavior, hostile-runtime, clean-load, deterministic float,
  resource-boundary, source-metric, and RuboCop proof. The catalog keeps one
  staged U1a1vt exception and no consumer until that unit adopts the boundary.

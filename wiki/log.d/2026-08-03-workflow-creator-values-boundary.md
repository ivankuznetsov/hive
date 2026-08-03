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
  Retained poisoned key objects now prove that path directly, and the
  exact-maximum comparison guard counts String `<=>`, `==`, and `eql?` behind a
  deliberately quadratic calibration so the equality counters cannot pass
  vacuously.
- Made the frozen capture and Marshal prototypes required anchors. Captured
  clone/raise operations, cloned singleton exception/backtrace/clone/copy/
  cause/message/string protocols, and a frozen matcher backed by the captured
  clean-load `Module#===` keep failures fresh, fixed, distinct, and
  `cause:nil` after each relevant post-load replacement and the combined
  surface. Failure creation no longer depends on `Exception#initialize`.
- Extended static require ownership and clean-load feature detection to
  catalog-owned `packaging/` paths. Declared packaging edges pass both checks;
  undeclared equivalents fail both, without weakening existing `lib/`
  isolation.
- Added focused behavior, hostile-runtime, clean-load, deterministic float,
  resource-boundary, source-metric, and RuboCop proof. The catalog keeps one
  staged U1a1vt exception and no consumer until that unit adopts the boundary.

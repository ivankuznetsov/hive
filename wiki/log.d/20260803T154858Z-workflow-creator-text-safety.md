---
title: Add bounded Workflow Creator text projection
type: change
created: 2026-08-03
tags: [architecture, component-boundaries, workflow-creator, text-safety]
---

- Added `HiveLiveAgentProof::WorkflowCreator::TextSafety` as the singular
  candidate entry point. It real-requires the existing Values leaf and exposes
  bounded UTF-8 text projection, safe-relative-path checks, ordered exact and
  patterned secret findings, and overlap-preserving redaction.
- Kept ownership explicit: public positive proof passes only
  `Values.capture(...).value`, while exact frozen plain-shape admission remains
  a documented internal contract rather than origin authentication. TextSafety
  captures its own private core handles and normalizes failures to one fixed
  secret-free error with no cause.
- Added red-first focused proof for byte boundaries, load order, unique secret
  scans, credential patterns, complete and truncated private-key envelopes,
  overlapping ranges, captured-handle privacy, and post-load core replacement.
- Closed the combined R43 proof at 298 lines / 20 callables / 32 decisions for
  Values, 200 / 14 / 23 for TextSafety, and 498 / 34 / 55 when composed. Both
  production files pass the per-method and 120-column RuboCop overlay.
- Expanded the same `workflow-creator-values` catalog row to own both files,
  kept it `candidate` with no Hive consumers, and moved its sole migration
  fence from U1a1vt to U1a1c. This change adds no schema, custody, publication,
  live-provider behavior, or boundary-readiness claim.

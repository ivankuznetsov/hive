## 2026-07-22 — Resume advanced managed draft-PR receipts

- Fixed managed worktree resume so immutable pointer identity is checked
  independently from the receipt's monotonic handoff phase.
- Preserved advanced phases such as `push_intent` for reconcile-first recovery
  instead of rejecting them as contradictions with the initial
  `worktree_created` receipt shape.
- Kept ordinary expected-state reads phase-sensitive and added an explicit
  identity-only comparison for the worktree resume boundary; simultaneous or
  malformed comparison inputs fail closed.
- Added focused receipt and real-worktree regressions covering every immutable
  identity mismatch plus authenticated resume from `push_intent` without
  resetting the receipt.

# 2026-07-16 — Patrol timeout and publication ledger hardening

- Fixer and Reviewer now treat `Agent#run!` status `:timeout` like `:error`: a timed-out
  agent's half-finished changes are never validated, shipped, or parsed as review output.
- PrOpener persists the fingerprint-to-PR mapping immediately after `gh pr create`, so a
  reconciliation miss or identity mismatch can no longer orphan a real open PR from the ledger.
- Control-worktree and scan-checkout cleanup failures no longer mask the in-flight exception
  (or discard a completed scan); added overlay-execution proof and pinned fingerprint-digest tests.

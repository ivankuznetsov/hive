# 2026-09-25 — Increment-1 daemon quiescence proof

- Real-process integration coverage now proves the idle checkpoint/proof path,
  same-generation status confirmation, fail-before-drain ownership refusals,
  detached-descendant persistence across controller restart, bystander safety,
  proof-publication crash recovery, and reconciliation before admission reopens.
- The same integration boundary now covers a paused historical quiescence
  revision: ordinary resume rejects schema skew without changing the database
  or proof, supervised `QuiescenceUpgrade` preserves the installation,
  generation, terminal attempt, and payload while invalidating the proof, and
  a later explicit resume is the step that reopens admission. An injected crash
  immediately after proof invalidation leaves the historical generation closed
  and retryable without restoring the old proof.
- The audited launch-coverage table qualifies no non-empty process surface as
  child-safe. Increment 1 is therefore explicitly idle-registry-only; agent
  roots and every registered service surface remain non-paused without verified
  delegated custody.
- Operator documentation now requires a paused acknowledgement for generation
  G followed immediately by same-G paused status before copying. A quiescing
  reading invalidates the copy, and only the runtime database plus its bound
  proof are inside the current backup claim.
- Darwin and Linux without usable custody retain the same fail-closed matrix.
  Creating the idle window remains an operator-coordinated gap rather than an
  implicit side effect of quiesce.

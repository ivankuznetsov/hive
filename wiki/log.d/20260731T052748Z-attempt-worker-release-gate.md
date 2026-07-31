---
title: Add a deterministic Attempts worker-release checkpoint
type: change
created: 2026-07-31
tags: [attempts, patrol, qualification, recovery]
---

- Added an optional, one-shot worker-release reader from
  `ConfiguredDispatcher` through `DetachedLauncher` and the private
  `AttemptSupervise` route to `Supervisor`.
- Preserved the incumbent no-gate handoff timing. With a gate, the supervisor
  persists the blocked Hive worker identity, reports readiness, and accepts
  only the byte `1` before releasing the existing authenticated Context gate.
- EOF, a closed reader, a wrong byte, an invalid inherited descriptor, and
  reader reuse all fail closed. The supervisor terminates a blocked worker and
  returns `TEMPFAIL` without terminalizing the running attempt.
- Added the qualification-private `after_module_decision` process-exit
  checkpoint. Its candidate process retains the sole writer and exits with
  private status 76 only after the admitted decision and worker identity are
  durable, leaving exact input for a fresh Reconciler.
- Focused tests pin no-gate timing, FD custody, valid release, EOF/wrong-byte
  cleanup, nonterminal recovery state, invalid descriptor rejection, one-shot
  ownership, and the real candidate-driver exit boundary.

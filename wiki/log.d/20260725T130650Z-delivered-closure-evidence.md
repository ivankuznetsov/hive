## 2026-07-25 — Evidence-bound delivered and superseded closure

**Action:** Added `Hive::TaskClosure` and the `hive-task-closure-input.v1` /
`hive-task-closure.v1` contracts. Authorized CLI, web, and allowlisted-bot
flows now verify canonical merged-PR or full-commit evidence, bind a preview to
the current task/marker generation, recheck remote/owner/worktree facts at
confirmation, persist a mode-0600 receipt, and archive through a private
receipt-only StageAction guard. Supersession additionally requires one
registered successor and bounded operator attestation. Corrupt, stale,
unsupported, identity-mismatched, or noncanonical-link receipts are
quarantined and never authorize transition; receipt-before-move crashes resume
idempotently.

**Surfaces:** Compatibility and operational status retain closure reason,
authority, digest, and canonical evidence links; archived task pages explain
delivery even when no worktree/diff remains. Operational actions advertise
that operator confirmation is required but cannot execute closure with an
observation token. Ordinary archive and attempt-journal authority remain
unchanged.

**Verification:** Focused tests cover schemas, same/cross-repository rules,
unsafe input, authorization, live-owner/worktree blockers, marker races,
quarantine, canonical-link rendering, crash resume, projection, transition
guard, StageAction isolation, operational advertisement, bot message editing,
and Rails authentication/CSRF. Live named-task dogfood remains recorded in
[[gaps]].

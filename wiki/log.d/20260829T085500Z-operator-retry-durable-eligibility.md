## 2026-08-29 — Operator retries remain due after durable admission

**Action:** Fixed generation-guarded `workflow.retry` actions that returned a
queued receipt but persisted the automatic marker-age deadline. The daemon
would reload that admitted request on its next tick and put it back into
cooldown, despite the explicit operator action.

Operator adapters now persist their action time as `next_eligible_at`. When an
automatic recovery request already owns the same marker generation, the
operator action makes that admitted request immediately due while preserving
its identity and single retry charge. Worktree safety, freshness, capacity,
quarantine, and every post-clear retry gate remain unchanged.

**Verification:** Recovery coordinator tests cover every operator adapter,
durable receipt replay, and acceleration of an existing admitted automatic
request.

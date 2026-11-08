# 2026-10-04 — A quota-only verification block points at retry

- When candidate verification exhausted its transient attempts because of a
  provider quota (for example Claude's five-hour limit), plan review blocked
  with "resolve verification blockers with a new linked plan". The plan was
  fine; the operator `hive plan-review TARGET retry` action is enough once the
  quota resets (hivedev's pin-raise task).
- When `candidate_verification_provider_limit` is the only non-finding
  blocker, the required action now reads "retry plan review after the
  provider limit resets (plan-review retry)". Other blockers keep the
  linked-plan instruction. The block itself, which is deliberate, is
  unchanged.

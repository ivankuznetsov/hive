# Keep bookkeeping losses on the execute-recovery route

Pass-4 review found that a lost attempt with a typed bookkeeping reason
(`runtime_bookkeeping_busy`, `first_heartbeat_owner_unverifiable_ceiling`)
published `AgentHealthy` with that reason, which `ExecuteWaitingAction` does not
recognise, so the task fell to `needs_input` (edit-resume and operator
notification) instead of `recover_execute`.

`AttemptObserver` now keeps `attempt_lost` as the condition reason and carries
the typed reason as `bookkeeping_reason` on the `attempt_lease` evidence. The
execute reconciler emits the same evidence field, so both producers agree.
Tests cover the observer evidence, the reconciler evidence, and the
`recover_execute` routing for both bookkeeping reasons.

## [2026-06-07T15:52:00Z] daemon — expose exhausted marker-heal budgets

**Action:** Added `marker_heal_exhausted` as a one-shot daemon log event when bounded marker auto-recovery gives up. The event now carries `budget_scope=per_process`, `suggested_next_action=manual_fix`, and a remediation hint so operators know the budget refills after daemon restart/SIGHUP and can recover manually. Strengthened finalize unpushed recovery tests for fresh marker-id retries, per-task budget isolation, race-shaped no-id marker guards, duplicate rows in one heal pass, and pre-clear baseline redispatch.

**Tests:** Verified `test/unit/daemon/stale_agent_healer_test.rb`, `test/integration/daemon_stale_agent_healing_test.rb`, and `test/unit/daemon/logger_test.rb`.

**Refreshed pages:**
- [[modules/daemon]]
- [[stages/finalize]]
- [[testing]]

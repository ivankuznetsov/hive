## [2026-08-23T21:25:58Z] status — reuse final attempt checkpoint bindings

**Action:** Changed bounded task-projection reads to trust terminal and lost
attempt bindings already recorded in a validated checkpoint. Those bindings
come from immutable permanent proof, so status now refreshes only mutable
attempts that can still transition. This removes repeated global attempt-store
lookups for historical attempts while preserving running-to-terminal
reconciliation.

**Verification:** Added a regression proving a cached terminal binding performs
zero attempt-store reads while the existing mutable-attempt reconciliation test
continues to pass. On the live 18-project dogfood registry, attempt binding
reads dropped from 6,751 to 185 and `hive status --json` wall time dropped from
5.73 seconds to 2.52 seconds before further per-task scan optimization.

**Refreshed pages:**
- [[commands/status]]

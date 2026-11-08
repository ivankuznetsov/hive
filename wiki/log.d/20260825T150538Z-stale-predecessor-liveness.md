# Ignore stale predecessor liveness after workflow progress

Operational status now treats a dead PID as stale ownership only while the
task's current action or marker still claims a running step. Durable Patrol Fix
receipt progress therefore wins over a dead predecessor lock: the task
reprojects as scheduler-owned and ready for its next transition, while normal
task-lock acquisition reclaims the stale file automatically.

The existing repair behavior remains for current `agent_running`,
`AGENT_WORKING`, and `REVIEW_WORKING` claims. A focused regression covers the
daemon-enrolled Patrol Fix case and verifies that stale predecessor attempt
identity is omitted from the `not_running` liveness cell.

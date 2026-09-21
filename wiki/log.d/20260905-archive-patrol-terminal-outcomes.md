# Archive rejected and handed-off Patrol Fix tasks

Rejected findings advance directly to the workflow archive, retaining their
rejected outcome. Escalations complete the existing idempotent coding-task
handoff before the same archive move, retaining their successor link and
escalated outcome. Failed handoffs leave the original active and retryable.
Blocked findings remain parked. Existing terminal decisions use the normal
scheduler advance path; no new cleanup service or stored lifecycle state.

Validation: projection, task-action/policy, and real archive-transition tests,
including handoff failure and retry without a new agent decision.

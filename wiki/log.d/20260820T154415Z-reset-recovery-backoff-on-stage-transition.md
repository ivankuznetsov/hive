# Reset recovery backoff after stage transitions

The durable recovery retry count is now scoped by project, task, and expected
workflow stage. Repeated failures in one stage still climb and hold at the
shared one-hour ceiling, while a successful stage transition starts the new
stage's failure series at the five-second step.

A real Webmail task entered execute successfully after extensive plan-review
recovery. Its first execute-side orphan marker inherited the plan stage's
retry count and was parked for an hour even though the execute defect had just
been fixed. Focused coordinator coverage now proves same-stage history remains
durable while cross-stage history cannot charge the new stage.

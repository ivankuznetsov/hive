# Repair markerless failed recovery attempts

**Problem:** A scheduler-owned recovery could launch and terminalize as failed
before its stage wrote a fresh error marker. The terminal recovery receipt then
overlaid a markerless task indefinitely, so the normal error healer had no
durable marker to schedule and an operator had to retry by hand.

**Change:** Execute now records raised implementation-spawn/stream exceptions
as `ERROR reason=implementer_failed status=exception` before propagating them
to the attempt receipt, while preserving restored tamper evidence as the more
important marker. As a restart/crash backstop, terminal delivery reconciliation
repairs a failed, cancelled, or lost recovery into
`ERROR reason=recovery_attempt_failed` only when the task still has the exact
unchanged markerless post-clear generation. Identity drift, progress, and any
meaningful marker fail closed.

Terminal delivery already holds the parsed claimed request. Reconciliation
uses that object directly instead of scanning and parsing the complete dispatch
queue once per terminal recovery.

**Operational consequence:** The existing stage-scoped retry ladder continues
autonomously after infrastructure exceptions. A new physical error marker
restarts the ordinary cooldown; no manual queue action or marker edit is
required.

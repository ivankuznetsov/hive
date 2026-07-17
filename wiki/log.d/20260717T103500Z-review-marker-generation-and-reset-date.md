# Review marker generation and reset-date preservation

**Action:** Review-owned `REVIEW_WORKING` and `REVIEW_ERROR` writes now receive
the same generated recovery identity as generic `ERROR` markers. Stale-agent
healing matches the observed identity and claims the task lock before clearing
a marker, preventing an old status row from disrupting a newer review run or
deleting a lock acquired after the snapshot.
Task locks now appear only after their complete payload is fsynced, carry a
generated lock id, and use ownership-scoped release. Status publishes the
verified holder identity, so wedged-review recovery terminates only the
observed process generation and clears a marker only after claiming the lock.
Generic descriptor stages also preserve a provider's raw quota reset text when
synthesizing `limits_reached`, so dated multi-day reset windows do not collapse
to the one-hour fallback.

**Verification:** Added marker rotation, stale review-generation, and dated
quota-envelope regressions alongside the existing focused agent/daemon suites.

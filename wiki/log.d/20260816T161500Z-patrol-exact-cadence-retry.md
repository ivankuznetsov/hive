# Ordinary Patrol preserves exact cadence through daemon arbitration

Ordinary Patrol now schedules its next timer evaluation from the last
completed run instead of from the daemon's most recent not-due check. A due
candidate consumes its cadence slot only after reservation, so a candidate
that loses the shared dispatch slot to Architecture Patrol is reconsidered on
the next daemon tick rather than sleeping for another full poll interval.

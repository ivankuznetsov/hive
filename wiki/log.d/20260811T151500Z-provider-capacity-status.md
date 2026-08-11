# Project provider capacity as scheduler waiting

Operational status now classifies the daemon's `attempt_capacity` disposition
as `waiting_on_provider_or_scheduler` with the scheduler as blocker owner.
Provider-account saturation no longer appears as a false ready or idle task.

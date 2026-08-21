# Refresh durable-attempt time at launch

Long daemon ticks no longer reuse their start timestamp when admitting a
durable child. Production injects a wall clock into the daemon dispatcher and
refreshes the request and attempt creation time at the final launch boundary,
so the configured claim window begins when the wrapper is actually spawned.

Previously a recovery-heavy tick could run longer than the 30-second launch
window before reaching later rows. Those rows received claim deadlines already
in the past; their detached wrappers then failed with
`launch claim deadline expired`, surfaced as `launch_handoff_failed`, and the
daemon could not advance any task late in the scan. A regression test exercises
a launch two minutes after tick start and pins the refreshed timestamp.

# Close bounded projection review gaps

The bounded task-local status implementation now also covers routine
finalization log retention and durable task-bound request validation: the
former consumes strict per-task projections through one sweep-wide attempt
reader, while the latter reuses one tick-wide dependency-admission context.
Neither path can reintroduce history- or queue-multiplied fleet scans.

Patrol Fix custody now protects every shared orchestrator-owned task file,
including journal and projection authority. Routine readers distinguish
transient lock contention from malformed lock entries, and exact repair fails
immediately rather than waiting forever on a held journal lock. Ad-hoc review
tasks record an authoritative generation-0 creation baseline so their derived
projection remains exactly repairable. Merge candidates also clear a stale
projection-outage archive block after healthy generation validation resumes.

# Runtime checkpoint roles and bounded daemon maintenance

Database connections now select explicit manual (4096-page automatic
checkpoint) or daemon-backed (disabled automatic checkpoint) policy across
cached connection adoption, reconnect, physical pool replacement and fork.
The daemon owns throttled PASSIVE maintenance under lifecycle and writer
fences, escalating from 30-second to one-second cadence above 16 MiB while
reporting deferred progress. Quiescence drains passively before its existing
checked FULL checkpoint; upgrade TRUNCATE completion checks remain.

Focused database, maintenance, daemon and lifecycle tests pass. The fixed-size
snapshot pinned-reader capture exceeded 16 MiB, then drained after reader
release and completed FULL/TRUNCATE within existing budgets. Full measurements
and the remaining combined-workload evidence are recorded in
`docs/implementation/runtime-database-contention.md`.

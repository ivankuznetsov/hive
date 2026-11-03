# Runtime writer timing and snapshot preparation

Added bounded operation labels and separate monotonic transaction wait/hold
measurements. Operational snapshots now encode their paired observation and
projection before the immediate transaction; row publication remains atomic.
The fixed five-writer fixture and initial negative long-hold reproduction are
recorded in `docs/implementation/runtime-database-contention.md`.

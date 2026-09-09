# Keep the terminal advance cache within its ownership boundary

PR #1196 now caches only Patrol Fix ready_to_advance rows. Full scans seed that
cache before dispatch, and dispatched, in-flight or terminal-replayed rows are
consumed immediately so an unrelated fast tick cannot re-admit an old approval.
Incremental replay also checks pending same-task requests before considering
cached contenders, preserving the explicit-request precedence of full ticks.

Removed a redundant priority sort and single-use action wrapper. Daemon wiki
prose now describes the final stage-and-age tie-break and shared row/request
arbitration rather than the superseded scheduler-prefix approach. Regressions
cover generic workflow exclusion, durable ownership outcomes, and pending
requests surviving cooldown; the original shortage reproduces on current main.

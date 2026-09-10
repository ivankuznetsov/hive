# Restore periodic Architecture Patrol dispatch

The unified Patrol cleanup deleted the module adapter that called
`ScheduledSliceProducer`, without connecting a replacement to the native daemon.
Producer unit tests and direct scheduled-command tests still passed; daemon
routing tests injected fake Architecture schedulers and never required periodic
work with an empty merged-PR queue.

Restored native daemon composition, bounded periodic candidates, a supervised
slice command, completion routing, cadence, and Architecture discovery allowance
checks. Regression coverage now includes daemon composition without merged jobs,
real schedulers through dispatcher launch/reap, and real producer/command cursor
advancement. Incomplete reviews and provider start failures release the slice.

Recovery now advances the cursor from retained completed results after an admission
failure, including a crash after admission is marked consumed. Live claims retain
ownership. Long admission occurrence IDs use a stable digest while preserving
existing short IDs. Regression tests cover nonempty durable admission, repeated
periodic launches, interrupted completion, and dry-run cadence.

Scheduled completion waits a full configured poll interval before the next attempt,
including failures and empty slices. Empty or allowance-exhausted children emit
`architecture_patrol_skipped` with a reason, rather than claiming a review closed.

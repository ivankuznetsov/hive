## [2026-10-30T15:18:00Z] runtime — close CI coverage gaps and stabilize project-rail submission

The review CI gate reported four uncovered lines: the contention budget's
default monotonic clock and sleep callbacks, wrapped busy classification while
pruning command receipts, and reraising unrelated database connection errors.
Focused unit cases now exercise these paths without relying on the separate
real-lock integration gate. Corrected the reported Ruby bracket/brace spacing.

The project-rail browser test could observe a live refresh after a successful
idea submission and miss the one-request Rails success flash. Waiting for the
redirect and then forcing a Turbo refresh reproduced the exact missing-flash
failure locally. The test now checks the durable task row and attachment plus
cleared composer state after that refresh.

Local verification: 347 focused Ruby tests (1,614 assertions), all 21 pipeline
browser tests (264 assertions), and repository-wide RuboCop passed. Instrumented
focused runs confirmed hits on all four CI-listed uncovered lines; the full
merged coverage gate remains for the runner's exact-head CI rerun.

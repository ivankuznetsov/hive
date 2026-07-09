## [2026-07-06T19:00:00Z] cli - hv rejects semver-then-hang probe via watchdog-fired sentinel

**Action:** Fixed Hive patrol finding `command-bin-hv` (bug/regression): a
candidate whose `hive --version` printed a bare semver, then hung and handled
the watchdog's TERM by exiting 0, was accepted — `wait "$pid"` recorded status
0, the captured semver matched the version regex, and `hv` exec'd the hung
candidate. This silently regressed the removed GNU `timeout` path, which
returned 124 for the same overrun and fell through to the next candidate.

`probe_version` now records a sentinel (`$output_file.timed-out`) the moment the
watchdog's arming delay elapses, and after teardown forces a non-zero status
(124, mirroring GNU `timeout`) whenever the sentinel is present — regardless of
the probe's own exit code. The fast path is untouched: a probe that finishes
before the timeout tears the watchdog down before it can write the sentinel.

Added `HvTest#test_candidate_that_prints_semver_then_hangs_is_rejected_not_exec_d`,
which asserts `hv` falls through such a candidate to a well-behaved one instead
of exec'ing it.

**Refreshed pages:**
- [[cli]]
- [[testing]]

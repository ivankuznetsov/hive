## [2026-07-24T08:28:32Z] CI — separate functional E2E from incident timing

**Action:** Kept the real CLI harness as a functional merge gate by adding its
result to the protected `rake test (Ruby 3.4)` aggregate. Moved the
report-driven incident duration check into a downstream `continue-on-error`
job that downloads the retained E2E artifact, so hosted-runner timing variance
stays visible without blocking a functional change. Kept report-integrity
checks in the functional E2E job.

**Contract:** Functional harness/library/scenario failures still fail the
protected aggregate, including missing enabled results, duplicate
metadata/results, and invalid durations. The advisory check retains only the
ten-second per-incident and thirty-second group targets, reuses the existing
report artifact, and does not repeat the E2E run or install the root bundle.

**Verification:** Added workflow-structure assertions for the required E2E
dependency, blocking integrity mode, advisory timing mode, artifact handoff,
and exclusion of timing from the protected aggregate.

---
title: Align release-candidate code with static-analysis gates
type: change
date: 2026-07-27
---

## [2026-07-27T17:42:11Z] release - satisfy lint and audit gates

**Action:** Applied the repository's RuboCop layout rules to the release
candidate implementation, recorded four scoped Brakeman command-injection
false positives for its discrete-argv subprocess calls, and made the coverage
job fetch release tags so baseline-catalog tests can inspect reviewed locks.

**Boundary:** The scanner ignores cover only calls whose candidate OIDs are
validated and whose remaining refs and paths are internal or supplied by the
reviewed, digest-pinned baseline catalog. No shell parses those arguments, and
the CI repair does not change release-candidate runtime behavior. Full Git
history is fetched only for the exhaustive coverage job that runs the
tag-dependent catalog checks.

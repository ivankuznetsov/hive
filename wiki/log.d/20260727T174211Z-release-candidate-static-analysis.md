---
title: Align release-candidate code with static-analysis gates
type: change
date: 2026-07-27
---

## [2026-07-27T17:42:11Z] release - satisfy lint and audit gates

**Action:** Applied the repository's RuboCop layout rules to the release
candidate implementation and recorded four scoped Brakeman command-injection
false positives for its discrete-argv subprocess calls.

**Boundary:** The scanner ignores cover only calls whose candidate OIDs are
validated and whose remaining refs and paths are internal or supplied by the
reviewed, digest-pinned baseline catalog. No shell parses those arguments, and
the CI repair does not change release-candidate runtime behavior.

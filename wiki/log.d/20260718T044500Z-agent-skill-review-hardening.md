## [2026-07-18T04:45:00Z] agents - harden provisioning prerequisites and timeouts

**Action:** Review-hardened managed agent-skill provisioning. Filtered target
resolution now recursively retains manifest-declared package prerequisites,
and adapter planning blocks a dependent package unless each prerequisite is
scheduled or proven healthy. Native inventory and install commands now run in
dedicated process groups with bounded TERM/KILL cleanup and reaping, preventing
a timed-out installer or descendant from continuing mutations after Hive has
reported failure.

**Safety and coverage:** Added real TERM-resistant parent/child cleanup
coverage, filtered-prerequisite resolution coverage, and fail-closed tests for
missing and unhealthy prerequisites. Updated [[commands/setup-agents]],
[[modules/agent_profile]], and [[testing]]; did not edit compiled [[log]].

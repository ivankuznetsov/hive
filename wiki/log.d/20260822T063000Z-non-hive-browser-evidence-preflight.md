# Non-Hive browser evidence preflights before the producer

Outcome-evidence capture now serves a temporary controller-owned readiness
page on the issued loopback application port while Hive verifies its managed
`agent-browser` session. Hive closes that listener before launching the
producer, which remains responsible for binding the real application to the
same port.

Previously only Hive Web had a controller-started application during this
preflight. For every other web project, including Rails applications, the
proxy reached an unbound port and returned 502. Pinned `agent-browser` 0.34.0
correctly rejected the navigation with `ERR_HTTP_RESPONSE_CODE_FAILURE`, so
all screenshot and video claims were incorrectly published as a permanent
`outcome_evidence_capability_blocked` result before the producer could run.

The readiness listener is bound to loopback, reachable only through the
existing random `.invalid` origin proxy, and released immediately after the
successful navigation. The producer still receives no browser socket and no
access to arbitrary localhost services. Focused tests prove the readiness
response traverses the real proxy boundary and that its application port is
free before production; a native smoke with Hive's pinned browser bundle also
completed successfully.

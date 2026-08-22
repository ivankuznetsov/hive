# Complete planner candidates survive malformed provider telemetry

OpenCode can finish a large planner revision and publish a valid candidate
while its bounded JSON export is truncated at process exit. Planner revision
previously discarded that complete, custody-verified artifact and scheduled a
full retry because only timeout telemetry had an artifact-precedence exception.

Planner revision now accepts any required output that passes ArtifactFirewall
custody, size and shape validation, and ends with the exact `COMPLETE` marker,
even when terminal provider telemetry reports failure. Provider diagnostics
remain recorded as a salvage receipt. Missing, incomplete, invalid, or
tampered outputs retain their existing failure behavior.

A regression test covers the observed OpenCode malformed-export failure after
a complete candidate was written.

Attempt receipts also record the planner-result contract version. An exhausted
transient series written under an older contract receives one automatic,
bounded recovery reset after Hive upgrades. This lets the daemon apply the
new artifact-precedence rule to a fresh attempt instead of leaving the task
blocked on an obsolete controller decision or requiring a synthetic plan
generation.

The task-action classifier also treats only a blocked transient planner route
whose recorded result contract is older than the running contract as
`plan_reviewing`. This makes the recovery reachable by the daemon while
leaving current blocked plan judgments parked.

Both contract-version readers parse the recorded version with `Integer()`, so
a receipt carrying a non-numeric string or a non-numeric type raises rather
than comparing. That case reads as stale in the orchestrator and in the
task-action classifier: an unreadable version is not a current verdict, so the
bounded recovery series runs instead of parking the task on a value Hive never
compared. Regression tests cover both readers for the string and non-numeric
type inputs.

# Admit only eligible bound benchmark evidence

The scorer writes schema version 2 and retains `judged`/`gated` as the ranked
aggregates. Only generated/successful empty-diff execution statuses and bound
current-artifact evaluations contribute. Raw judges, gates, failure statuses
and available attempt costs remain inspectable. Coverage reports attempted,
eligible, judged and gated populations separately; pipeline and Hive measured
wall time now contribute alongside fresh runs. See the delivery inventory at
`docs/bench-runtime-inventory.md` for canonical revision and consumer scope.

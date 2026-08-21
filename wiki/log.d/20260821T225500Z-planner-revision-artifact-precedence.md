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

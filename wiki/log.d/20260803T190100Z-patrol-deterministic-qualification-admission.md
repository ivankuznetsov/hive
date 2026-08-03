# Admit deterministic patrol evidence through one facade

`Hive::Modules::Migration::Patrols` now accepts bounded raw receipt documents
and independently computed expected bindings, verifies every receipt, builds
the deterministic qualification, and digest-CAS merges the existing report-v2
projection. The facade does not run scenarios, collect evidence, or own retry,
provider, process, cutover, or recovery behavior.

This keeps U3b's deterministic E2E campaign outside production architecture:
the harness can exercise real Patrol paths and hand observations to one public
admission boundary without constructing verifier tokens, qualifications, or
report projections itself.

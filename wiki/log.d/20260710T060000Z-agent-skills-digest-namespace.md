## [2026-07-10T06:00:00Z] agents - make provisioning digests load-order safe

**Fix:** Qualified provisioning SHA-256 references as top-level
`::Digest::SHA256`. In the complete suite, loading the existing `Hive::Digest`
feature before agent-skill adapters caused Ruby constant lookup to select
`Hive::Digest` and fail planning; focused agent-skill tests had not loaded that
unrelated namespace. Adapter/provisioner tests now deliberately load
`hive/digest` first to pin the collision regression.

**Verification:** Focused adapter, provisioner, and process-level setup
acceptance suites pass with the colliding namespace loaded. Did not edit
compiled [[log]].

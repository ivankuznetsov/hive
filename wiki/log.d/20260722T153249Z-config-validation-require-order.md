# Config validation no longer depends on command require order

**Action:** `Hive::Workflows::Project` now derives the registered stage-name
union directly from `Registry.all` while validating strict project root keys.
This preserves the standalone loader contract used by command paths such as
`hive markers clear`, which load `Project` through `Task` without first loading
the aggregate `hive/workflows` entrypoint.

**Validation:** Added a clean Ruby subprocess regression for the markers-command
require order. Added explicit coverage for unsupported-config propagation and
invalid workflow-path guards, including the exact status boundaries that must
not degrade an unsupported root key. The `stale_lock_recovery` E2E scenario
remains the CLI-level contract that exposed the failure.

Did not edit compiled [[log]].

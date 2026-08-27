# Bind source Hive to its matching agent runtime component

**Action:** `bin/hive` now prepends the monorepo
`components/agent-cli-runtime/lib` directory when that source-only component is
present, before loading Hive.

**Reason:** A dogfood OpenCode benchmark clone loaded the separately installed
`agent-cli-runtime` gem instead of the component from the cloned commit. The
installed gem did not yet accept Hive's `bash_patterns` preparation keyword,
so planning failed before OpenCode could run.

**Verification:** Added a subprocess regression proving a source `bin/hive`
loads an `OpenCodePreparationRequest` with the checkout's `bash_patterns`
contract even when the installed gem is older. Reproduced the test red before
the load-path change and green afterward.

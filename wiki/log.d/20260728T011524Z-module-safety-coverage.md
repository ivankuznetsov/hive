# Make module safety coverage host-independent and exhaustive

- Removed the module command-target test's dependency on whether the CI host
  happens to have Bubblewrap installed; the test now isolates host discovery
  while retaining the fail-closed network-allowlist assertion.
- Added direct coverage for module lifecycle ownership conflicts, immutable
  target snapshots, migration admission races, retry reconciliation, corrupt
  state, legacy cleanup, and patrol capability declarations.
- Kept the production safety contracts unchanged while making the 100% coverage
  gate prove their error and recovery arms deterministically on every runner.

**Pages:** [[testing]] [[commands/refactor-patrol]]

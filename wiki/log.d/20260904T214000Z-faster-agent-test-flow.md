# Faster local agent test flow and measured CI partitions

The local implementation loop now starts with `bin/test --changed --list` and
`bin/test --changed`, including test-only, staged, unstaged, untracked, deleted,
component, and Rails changes. Owner-based selection falls back visibly; it does
not replace the full CI coverage proof. `bin/test --all` runs the full local
manifest and Agent CLI Runtime suite in two isolated worker processes, with a
per-user host lock, retained worker logs, failure propagation and process-group
cleanup. Short temporary directories outside Git checkouts preserve socket and
repository-discovery tests. PID-bound result receipts reject silent early exits
and require actual runs/assertions across filtered workers. Up to four workers
are explicit via `HIVE_TEST_WORKERS`.

CI's six collectors now use checked-in nightly runtime estimates with a byte
fallback. Partition completeness, artifact identity, all dedicated proof gates,
and the exact 100% global coverage requirement remain unchanged. Focused
coverage disables unrelated preloads and child reports, merges once and rejects
unloaded selected sources and collector errors.

Nightly checkout fetches complete history/tags. The Pi output-exhaustion test
accepts both natural exit and the deliberate SIGTERM cleanup path while
rejecting timeout. The installer fixture directly execs Ruby rather than
booting an intermediate Ruby wrapper: the same 45 tests/273 assertions and seed
fell from 78.43s to 38.32s locally. Task-capture's much higher hosted timing was
not reproduced; its real lifecycle proofs remain intact.

The OpenCode offline smoke fixture uses a route present in the isolated native
catalog, with its high variant still validated. Web selection includes root web
contract tests; implicit source selection excludes dedicated CI-only gates.

Local validation: `HIVE_TEST_WORKERS=4 bin/test --all` passed 14,184 tests and
286,822 assertions with zero failures/errors in 362.77s. All 1,811 Ruby files
passed RuboCop. The exhaustive serial `rake coverage` gate also passed: 95,687
of 95,687 lines across 745 sources (100%), 1,798 process results, no unloaded
files or collector errors. Its root test phase took 1,493.75s, confirming why
this gate stays outside the normal agent iteration loop. These are individual
local measurements; they do not establish the hosted CI speedup or a matched
before/after ratio.

See [[testing]] for commands and [[gaps]] for measurement limitations.

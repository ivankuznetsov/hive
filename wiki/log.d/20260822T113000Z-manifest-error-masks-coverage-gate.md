# The shard-manifest error masks the real coverage number

**Problem:** CI reported two red jobs whose logs named neither a failing test
nor a coverage percentage:

- `coverage (Ruby 3.4)` aborted after 12s with
  `coverage shard manifest error: coverage shard manifest does not match its
  process results`.
- `rake test (Ruby 3.4)` aborted after 4s. That job runs no tests at all — its
  only step asserts `HIVE_COVERAGE_RESULT = success`, so it is a gate that
  restates the coverage verdict.

All six `coverage shard N/6` jobs were green, which makes the pair look like
pure infrastructure noise. It is not: `coverage:report` verifies the manifests
*before* `HiveTestCoverage.report!`, so the manifest error aborts the run
before the exact-100% line gate is ever evaluated. A real coverage shortfall
sits behind it, invisible.

**Cause of the manifest error:** `coverage:collect` writes the manifest by
globbing `*.marshal` after the shard's tests finish, and `coverage:report`
re-globs the same directory inside the uploaded artifact. A child process that
dumps its coverage between those two points adds a file the manifest does not
list. Here shard 0 carried exactly one extra result whose payload was a
`bin/hive` CLI subprocess — a pre-existing late-dumping child, unrelated to the
change under test. `gh run rerun --failed` cannot clear it, because the stale
manifest is inside the already-uploaded artifact; the whole workflow must run
again.

**Recovering the hidden number:** the six shard artifacts are sufficient to
reproduce the gate locally. Download them, rewrite the `/home/runner/work/hive/hive`
path prefix in each marshal to the local source root, drop the rewritten files
into `coverage/.resultset/<run-id>/`, then call `HiveTestCoverage.report!`
without `HIVE_COVERAGE_EXPECTED_SHARDS` so the manifest check is skipped. That
recovered `99.99% (97616/97626)` and named all ten uncovered lines directly.

**Practice:** when the manifest error appears, never treat it as the whole
failure. Merge the artifacts and read the real gate number first — otherwise a
rerun clears the manifest race and reveals the coverage shortfall as a second
red run.

See [[artifacts]].

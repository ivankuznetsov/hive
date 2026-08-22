# CI velocity now separates proof, measurement, and policy

**Date:** 2026-08-22
**Scope:** `.github/workflows/{ci,install-smoke,nightly-flake-sweep}.yml`,
`Rakefile`, `bin/test`, `script/flake_sweep*.rb`, `test/support/`, `wiki/testing.md`

PR #1167's recovery keeps the improvements that are useful without prior
measurement: bounded jobs, aggregation summaries, complete coverage exports,
root-Minitest failure evidence, caches, and the focused local loop. Required CI
runs unconditionally and remains on the hosted-proven six-way byte partition.

Three premature policy mechanisms were removed. Broad docs-only classification
could bypass tests that read `docs/`; an empty quarantine and `minitest-retry`
dependency protected no evidenced flake; and runtime partitioning had no
checked-in timing input. The nightly sweep now produces the evidence those
features would need, but no required gate consumes it automatically.

The repaired sweep loads Minitest before reporter registration, binds each
report to the full suite manifest, and accepts only one report for each of seeds
101, 202, and 303. Missing, duplicate, corrupt, or suite-mismatched input emits
no derived artifacts. A complete failing matrix writes its candidate and timing
artifacts and updates the tracking issue before a final step reports the red
verdict.

`bin/test` now loads every leading test-file argument and forwards the remaining
flags once to Minitest in both Bundler and plain-Ruby modes. Changed-source
coverage no longer guesses by basename: mirrored paths and explicit overrides
are the only trusted mappings. Absolute TUI latency has a named advisory job;
required CI continues to own functional behavior and archive-size scaling.

The remaining hosted evidence boundary is recorded in [[gaps]]: the new nightly
workflow and advisory latency lane need default-branch runs before a later PR
can justify runtime rebalancing or retry policy.

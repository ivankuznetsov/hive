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
report to the full suite manifest, records whether every suite file loaded, and
accepts only one positive, equal test count for each of seeds 101, 202, and 303.
Missing, duplicate, corrupt, incompletely loaded, zero-test, count-mismatched,
or suite-mismatched input emits no derived artifacts. A complete failing matrix
writes its candidate and timing artifacts and updates the exactly titled
tracking issue before a final step reports the red verdict. The generated issue
points only to confirmed reproduction and raw timing evidence; it does not
advertise the retired quarantine or timing consumer.

`bin/test` now loads every leading test-file argument and forwards the remaining
flags once to Minitest in both Bundler and plain-Ruby modes. Changed-source
coverage no longer guesses by basename: mirrored paths and explicit overrides
are the only trusted mappings, and the task reuses `bin/test` so multiple
mapped files cannot silently collapse to the first Ruby script. Failure repro
commands are assembled from a shell-escaped argument vector, including source
paths with spaces. Absolute TUI latency has a named advisory job; required CI
continues to own functional behavior and archive-size scaling.

Failure-evidence uploads warn when their expected file is absent, and the e2e
failure payload is a separate artifact so it cannot change the stable
`hive-e2e-report` archive root used by the advisory timing consumer. The local
changed-coverage proof requires the locked bundle even though direct `bin/test`
use still supports a clearly labelled plain-Ruby fallback.

The remaining hosted evidence boundary is recorded in [[gaps]]: the new nightly
workflow and advisory latency lane need default-branch runs before a later PR
can justify runtime rebalancing or retry policy.

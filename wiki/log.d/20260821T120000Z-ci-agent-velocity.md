# CI agent velocity: flake handling, failure evidence, and a fast local loop

**Date:** 2026-08-21
**Scope:** `.github/workflows/{ci,install-smoke,nightly-flake-sweep}.yml`,
`Rakefile`, `test/support/{failure_evidence,changed_coverage}.rb`,
`script/flake_sweep*.rb`, `bin/test`

## What changed

CI now optimizes for the consumer that reads it — agents — without weakening
any gate. Every job has an explicit `timeout-minutes`; aggregator jobs
self-describe via step summaries; failing suites emit machine-readable
evidence (step summary + JSON artifact with failing test, seed, and exact
single-test repro command), and each root-Minitest-owning job retains it.
Wall-clock latency assertions in the TUI state-source test and the e2e
provider-limit recovery-receipt scenario (3s) became generous eventually-bounds;
absolute TUI budgets moved to a visible advisory job while machine-independent
scaling remains required. Coverage stays on the hosted-proven six-way byte
partition. Playwright browsers and the golden-path root bundle are cached.

The nightly seed sweep is an evidence producer, not an implicit policy change:
it admits only the complete 101/202/303 matrix with an identical suite-manifest
digest, retains complete failing analysis before its final verdict, and emits
timings plus flake candidates for a later reviewed PR. Required CI does not
skip broad docs paths, path-filter install-smoke, retry an empty quarantine
list, or consume absent runtime timings.

The local fast loop is `rake coverage:changed` (changed lib sources to explicit
or mirrored tests to exact coverage on those sources) plus the bundler-optional
`bin/test` wrapper, which loads every supplied file. Both are documented in
[[testing]].

Two constraints this change set has to respect, both now covered by tests:

- Every root Minitest job needs the same failure-evidence retention seam;
  workflow-contract coverage enumerates the coverage, expensive-gate, e2e,
  advisory-latency, and launchd owners.
- A seed count is not completeness. The analyzer validates exact unique seed
  identities, report schema, each report's manifest digest, and equality of
  the full suite file list before writing any derived output.

## Uncertainties

- The named suspected flakes still need exact identifiers from a complete
  hosted sweep before any retry policy can be proposed.
- Runtime rebalance quality depends on a real hosted timing artifact; no timing
  consumer ships in this change.

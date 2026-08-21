# CI agent velocity: flake handling, failure evidence, and a fast local loop

**Date:** 2026-08-21
**Scope:** `.github/workflows/{ci,install-smoke,nightly-flake-sweep}.yml`,
`Rakefile`, `test/support/{failure_evidence,flake_quarantine,shard_partition,
changed_coverage}.rb`, `script/flake_sweep*.rb`, `bin/test`, `Gemfile`

## What changed

CI now optimizes for the consumer that reads it — agents — without weakening
any gate. Every job has an explicit `timeout-minutes`; aggregator jobs
self-describe via step summaries; failing suites emit machine-readable
evidence (step summary + JSON artifact with failing test, seed, and exact
single-test repro command). Known-flaky tests get quarantine-with-retry via
`minitest-retry` and `test/support/flake_quarantine.rb` (list intentionally
empty until sweep evidence names entries; retries are loud and budgeted).
Wall-clock latency assertions in the TUI state-source test (1.5s) and the e2e
provider-limit recovery-receipt scenario (3s) became generous eventually-bounds;
latency budgets stay with the TUI reactivity perf gate and the advisory
incident-duration-budget job. Coverage shards partition by measured per-file
runtimes from the checked-in sweep timings file (byte-size hot/tail fallback);
only baseline-catalog shards unshallow. Playwright browsers and the golden-path
root bundle are cached. Pure docs diffs short-circuit heavy proofs while all
required checks still report; install-smoke is path-filtered.

The local fast loop is `rake coverage:changed` (changed lib sources → focused
tests → exact coverage on those sources) plus the bundler-free `bin/test`
wrapper, documented in [[testing]].

## Uncertainties

- The two known-flaky tests named during planning (capture-provider seed-order
  flake; web tasks sandbox race) are not yet in the quarantine list — their
  exact identifiers need sweep evidence; the nightly workflow will surface them.
- Shard rebalance quality depends on the first real timings landing from the
  nightly sweep (`workflow_dispatch` to exercise it end-to-end).

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

Two constraints this change set has to respect, both now covered by tests:

- The coverage-shard job's conditional unshallow shells out to bundler, so it
  must run **after** `ruby/setup-ruby`. Placed before it, every shard dies in
  seconds with `bundle: command not found` and the coverage aggregator gate
  reports the failure with no test output to explain it.
  `CiTestPartitionTest#test_every_workflow_sets_up_ruby_before_shelling_out_to_bundler`
  asserts the ordering across every workflow file.
- `HiveFlakeQuarantine.activate!` runs from `test_helper`, so a hard
  `require "minitest/retry"` would make *every* test file unloadable on a
  machine with no installed bundle — which would defeat the bundler-free
  `bin/test` path. It raises under Bundler (CI, `bundle exec`) and degrades to
  "no retries" with a warning otherwise.

## Uncertainties

- The two known-flaky tests named during planning (capture-provider seed-order
  flake; web tasks sandbox race) are not yet in the quarantine list — their
  exact identifiers need sweep evidence; the nightly workflow will surface them.
- Shard rebalance quality depends on the first real timings landing from the
  nightly sweep (`workflow_dispatch` to exercise it end-to-end).

# Merge main (CI velocity) into benchmark runtime follow-up

Merged `main` (faster-to-diagnose CI without weaker gates #1167) into
`fix/opencode-benchmark-runtime-followup` to clear `BEHIND` — `main` requires
branches be up to date (`required_status_checks.strict`), so being one commit
behind blocks merge on its own even with every check green.

The merge was clean: no file conflicted. #1167 is confined to the test
harness (`bin/test`, `test/support/coverage_config_sandbox.rb`,
`test/support/failure_evidence.rb`, `script/flake_sweep*.rb`) and the tests
that cover it, none of which this branch touches. The CI shard partition is
computed by `Dir.glob`, not a checked-in manifest, and this branch adds no new
test files, so the merge needs no partition regeneration.

`bin/test` arrives with this merge and supersedes plain
`ruby -Itest -Ilib <file>` for local runs: it prefers the locked bundle and
falls back to plain ruby when bundler is absent. The fallback still cannot
serve gems to *subprocesses* a test spawns, so three tests fail locally
without bundler and pass in CI — `ci_test_partition_test.rb`'s
`test_ci_gate_tasks_fail_when_no_non_skipped_asserting_test_runs`
(`minitest/autorun`) and `bench_test.rb`'s two
`*_quota_marker_has_canonical_recovery_identity` tests (`agent_cli_runtime`).
All three reproduce on their pre-merge baselines; treat them as environmental.

See [[testing]], [[modules/workflows]].

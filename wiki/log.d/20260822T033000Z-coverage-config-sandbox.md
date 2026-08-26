# Coverage config leak: `configure!` without restore loses a whole shard

`test/unit/coverage_evidence_test.rb` called
`HiveTestCoverage.configure!(root: Dir.mktmpdir(...))` in `setup` and never
restored it. `configure!` mutates the module singleton (`@root`, `@lib_dir`,
`@coverage_dir`, `@resultset_dir`), so after that file ran, the shard's own
`at_exit` `dump_process_result!` wrote its marshal into the scratch directory
instead of `coverage/.resultset/<run id>`. The shard exited zero and CI
reported it green, while the merged gate lost every line that process had
measured — 3095 of PR #1167's 4287-line deficit sat in the one shard that
owned the leaking file, which is why the shortfall appeared to migrate on
every repartition.

Proof: running `coverage_evidence_test.rb` alongside `tui/clipboard_test.rb`
under the coverage boot covered 71 lines of `lib/hive/tui/clipboard.rb`
before the fix and 205 after it.

Fix: `test/support/coverage_config_sandbox.rb` snapshots and restores every
coverage state ivar. `coverage_test.rb`'s private `with_coverage_config`
helper moved there (it already did this correctly, which is why its shard
only lost 106 lines), and `coverage_evidence_test.rb` now restores in
`teardown`. Regression coverage: two sandbox round-trip tests plus a lint
test that fails any `_test.rb` calling `configure!` with no restore path.

See [[testing]].

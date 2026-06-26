## [2026-06-25T01:28:48Z] cli - wrapper argv encoding preflight

**Action:** Added pre-dispatch `ARGV#valid_encoding?` guards to `bin/hive` and
`bin/hive-e2e` so invalid-byte arguments route through existing usage-error
formatting instead of Thor/Ruby internal errors. `bin/hive run --json <invalid>`
now emits the command-specific `hive-run` error envelope with exit 64;
`bin/hive-e2e replay --json <invalid> ...` emits `hive-e2e-error` with
`error_kind: "usage"` and exit 64.

**Verified:** `bundle exec ruby -Itest -Ilib test/integration/cli_usage_error_json_test.rb`;
`bundle exec ruby -Itest -Ilib test/e2e/lib/hive_e2e_binary_test.rb`;
`bundle exec rubocop bin/hive bin/hive-e2e test/integration/cli_usage_error_json_test.rb test/e2e/lib/hive_e2e_binary_test.rb`.

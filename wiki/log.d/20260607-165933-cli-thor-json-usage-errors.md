## 2026-06-07 - CLI Thor JSON usage errors

**Action:** Fixed the `bin/hive` boundary so Thor argv/usage errors are re-raised to the entrypoint instead of exiting before command-level JSON handling. Missing-argument forms of `hive run --json`, `hive approve --json`, and `hive markers clear --json` now emit their existing command schemas with `ok=false`, `error_class=InvalidTaskPath`, `error_kind=invalid_task_path`, and EX_USAGE (64). Added subprocess regression coverage in `test/integration/cli_usage_error_json_test.rb` and refreshed [[cli]] / [[testing]].

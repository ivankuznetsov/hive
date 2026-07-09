## [2026-07-09T00:23:03Z] cli - JSON usage contracts for setup and Screenote

**Action:** Added `bin/hive` wrapper-level JSON usage contracts for `hive setup`,
`hive connect`, and `hive disconnect` so Thor pre-dispatch failures keep a
parseable stdout document under `--json`. `setup` now emits an unversioned
`hive-setup` `ok:false` usage payload for extra positionals, while Screenote
connect/disconnect missing-`SERVICE` failures emit the existing schema-less
Screenote failure family with `service:"screenote"` and `error_kind:"usage"`.

**Tests:** Added focused wrapper integration coverage for `hive connect --json`,
`hive disconnect --json`, and `hive setup extra --json` in
`test/integration/cli_usage_error_json_test.rb`; `bundle exec ruby -Itest
test/integration/cli_usage_error_json_test.rb` passed.

**Refreshed pages:** [[cli]], [[commands]], [[commands/setup]],
[[commands/screenote]], and [[testing]]. Did not edit compiled [[log]] or run
`qmd update` / `qmd embed`.

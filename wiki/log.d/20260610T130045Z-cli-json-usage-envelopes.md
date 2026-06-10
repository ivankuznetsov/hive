## [2026-06-10T13:00:45Z] cli — route wrapper JSON usage errors

**Action:** Extended `bin/hive`'s pre-dispatch Thor usage-error JSON mapping beyond `run` / `approve` / `markers`. Missing-target workflow verbs now emit `hive-stage-action` error envelopes with `verb`, `pr` maps to `open-pr`, `prune` pre-dispatch usage failures emit `hive-prune` with `error_kind: usage`, and compatible schema-backed surfaces such as `drop`, `findings`, `patrol`, and `status` now avoid empty-stdout Thor prose under `--json`. Refreshed [[cli]] and [[testing]] for the wrapper contract.

**Tests:** `bundle exec ruby -Itest test/integration/cli_usage_error_json_test.rb`; `bundle exec ruby -Itest test/integration/cli_version_test.rb`; `bundle exec ruby -Itest test/unit/schema_files_test.rb`; `ruby -c bin/hive`; `ruby -c test/integration/cli_usage_error_json_test.rb`.

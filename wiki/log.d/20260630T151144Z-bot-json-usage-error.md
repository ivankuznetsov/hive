## [2026-06-30T15:11:44Z] cli - bot extra positional JSON usage errors

**Action:** Restored the `bin/hive` `JSON_USAGE_ERROR_CONTRACTS` entry for
`bot`, so Thor pre-dispatch arity failures such as
`hive bot status extra --json` emit a parseable `hive-bot-status.v1`
ErrorPayload on stdout with `error_kind: "extra_arguments"` and exit `64`
instead of returning only Thor prose on stderr.

Updated `schemas/hive-bot-status.v1.json` with the narrow ErrorPayload arm and
added a focused regression in `test/integration/cli_usage_error_json_test.rb`
that validates the emitted document against the published schema. Refreshed
[[cli]], [[commands/bot]], and [[testing]]; [[index]] did not need a page-list
change.

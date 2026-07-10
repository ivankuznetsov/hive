## [2026-07-10T17:00:00Z] CLI — exhaustive pre-dispatch JSON usage envelopes

**Action:** Replaced `bin/hive`'s partial command map with schema-derived usage contracts for ordinary versioned commands and CLI-owned overrides for aliases, multi-surface commands, and unversioned envelopes. Thor arity failures now emit one command-shaped JSON document for the previously uncovered init, registry cleanup, doctor/setup, Screenote connect/disconnect, bench, status, web, and metrics surfaces. Added a schema-valid `hive-init.v1` usage arm and the `hive-forget.v1` `usage` error kind.

**Tests:** Expanded `test/integration/cli_usage_error_json_test.rb` with a table-driven executable matrix, including schema validation for registered envelopes.

**Refreshed pages:**
- [[cli]]
- [[testing]]
- [[commands/init]]
- [[commands/forget]]
- [[commands/prune]]
- [[commands/digest]]
- [[gaps]]

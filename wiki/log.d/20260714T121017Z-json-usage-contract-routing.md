---
title: Exhaustive JSON usage-error contract routing
type: change
tags: [cli, json, thor, schemas, testing]
---

**Action:** Expanded `bin/hive`'s pre-dispatch JSON usage-error resolver so
malformed invocations retain the requested command shape across doctor,
Screenote connect/disconnect, setup, status/diagnose, forget/prune, metrics,
pairing, daemon queue/enrollment, and web install/status. Versioned surfaces
continue through `Hive::Schemas::ErrorEnvelope`; Screenote, metrics, and daemon
queue keep their narrower native error payloads. Added `usage` to the additive
`hive-forget.v1` error-kind vocabulary for wrapper-owned malformed argv.

**Tests:** Extended `test/integration/cli_usage_error_json_test.rb` with
table-driven subprocess coverage for omitted top-level routes and
subcommand-specific schemas, including invalid-byte argv before Thor dispatch.
Verified the focused wrapper suite, schema-file suite, and RuboCop.

**Refreshed pages:**
- [[cli]]
- [[testing]]
- [[commands/doctor]]
- [[commands/forget]]
- [[commands/prune]]
- [[commands/screenote]]
- [[commands/setup]]

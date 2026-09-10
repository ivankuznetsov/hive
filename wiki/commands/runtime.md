---
title: hive runtime
type: command
source: lib/hive/commands/runtime.rb, lib/hive/runtime_control_plane/installation.rb
updated: 2026-09-09
tags: [command, sqlite, status]
---

`hive runtime status [--json]` validates the current SQLite database read-only.
Healthy storage reports `active`; missing storage reports `absent`, exits 1 and
points to `hive setup`. Unsupported or corrupt storage returns a typed error.
The JSON contract is `hive-runtime-maintenance.v1`. `resume` is not supported.

`Installation.setup` serializes explicit setup, builds a complete current database
privately and publishes without replacing an existing destination. Repeated setup
validates the existing database and preserves identity and data. Startup validates
existing storage without creating or migrating it; fresh commands that do not
require runtime storage remain available before setup.

No cutover manifests, historical import, retired-writer sealing, service replay or
activation phase state machine remains. Current schema/application identity,
installation identity, private storage custody and integrity validation remain.
Historical activation columns remain inert in the current schema so existing
current databases do not require another conversion.

Tests: `test/unit/runtime_control_plane/installation_test.rb`,
`activation_gate_test.rb`, `database_test.rb`, and `test/unit/commands/runtime_test.rb`.

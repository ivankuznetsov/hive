---
title: hive runtime
type: command
source: lib/hive/commands/runtime.rb, lib/hive/runtime_control_plane/installation.rb, lib/hive/runtime_control_plane/database.rb
updated: 2026-10-03
tags: [command, sqlite, status, read-only]
---

`hive runtime status [--json]` validates the current SQLite database read-only.
Healthy storage reports `active`; missing storage reports `absent`, exits 1 and
points to `hive setup`. Unsupported or corrupt storage returns a typed error.
The JSON contract is `hive-runtime-maintenance.v1`. `resume` is not supported.
For a current database, the result also includes a distinct read-only
`lifecycle` object (`phase`, `generation`, `revision`, and `admission_open`).
This does not replace installation health: storage remains `active` while work
is quiescing or paused. Missing storage reports `lifecycle: null`.
`hive runtime status` is not a backup acknowledgement. The increment-1 backup
contract requires a successful `hive daemon quiesce --json` followed
immediately by `hive daemon status --json` reporting the same paused generation
with valid proof and clear liveness.

On Linux, runtime status can inspect a read-only state root through this policy
only when the actual path has available, unambiguous `/proc/self/mountinfo`
metadata confirming the read-only mount. No sidecars uses an immutable
read-only connection; a readable WAL/SHM pair uses plain read-only inspection;
and either sidecar alone is refused. The command never
checkpoints, removes, repairs, or creates sidecars. A pair that needs forbidden
WAL-index recovery returns a read-only storage error instead of retrying with
immutable access.

`state_storage_read_only` normally directs the caller to `Use a writable,
accessible state root (HIVE_HOME).` An unpaired sidecar instead uses `Use a
writable state root (HIVE_HOME), or safely restore a matching WAL/SHM pair or
remove the stray sidecar after verifying no committed data will be lost.`
`state_storage_inaccessible` uses the general writable, accessible state-root
action. These access failures never recommend backup recovery. Confirmed
corruption and custody violations retain their existing codes and backup
action; in particular, a different-uid audit remains
`database_custody_invalid`. Auditing as another uid is unsupported.

Non-Linux platforms, including macOS, and Linux hosts with missing or ambiguous
procfs mount metadata cannot authorize immutable inspection. A typed read-only
failure there returns `state_storage_read_only` and the general action rather
than a successful status document. JSON storage failures use the
`hive-runtime-maintenance.v1` fields `runtime_code` and `next_action`. Because
runtime status shares this policy, it should not be recommended as a recovery
step for a path where the same inspection has already failed.

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
`activation_gate_test.rb`, `database_test.rb`, `test/unit/commands/runtime_test.rb`,
and the real-mount `test/integration/status_read_only_test.rb` gate.

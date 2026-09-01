---
title: hive runtime
type: command
source: lib/hive/commands/runtime.rb, lib/hive/runtime_control_plane/cutover.rb
created: 2026-08-30
updated: 2026-08-30
tags: [command, sqlite, runtime-control-plane, status, resume, recovery]
---

**TLDR**: `hive runtime` diagnoses the SQLite activation state and resumes an
interrupted one-way cutover. It never creates, migrates, restores, or
downgrades implicitly.

## Usage

```bash
hive runtime status [--json]
hive runtime resume [--json]
```

Every JSON call emits the strict `hive-runtime-maintenance.v1` envelope with
`schema_version`, action, and a typed result or error. Errors retain the runtime
code, next action, and structured details. The early activation gate emits this
same contract before the normal CLI loads, so `--json` callers never receive a
prose-only maintenance refusal.

## Status

`status` is read-only. It validates the immutable cutover manifest, the exact
SQLite schema and application identity when a database exists, installation
lineage, and activation epoch. A healthy database beside a missing, corrupt, or
identity-mismatched manifest is an error rather than an inferred active
installation.

The durable phases are:

- `preparing`: the exact prior service state is journaled and services are
  being stopped. A retry reuses that journal rather than observing a new state.
- `ready`: services and live owners are quiesced and task authority is
  fingerprinted; no legacy writer has been fenced yet.
- `intended`: retired writers are fenced and the rebuilt SQLite database is
  installed; activation must converge forward.
- `active`: the database identity is authoritative and the ordinary-command
  gate is open. Service replay then converges idempotently from the private
  service journal, whose `activated` checkpoint prevents duplicate launchctl
  starts after a crash.

An incomplete result reports `hive runtime resume` as the action. Hive offers
no rollback, restore, or downgrade command for this irreversible transition.

## Resume

`resume` reopens the recorded manifest and continues from its durable phase. It
revalidates task fingerprints, holds an exclusive legacy-usage transaction from
snapshot comparison through fencing, installs the fully validated candidate
database idempotently, publishes `active`, and then replays only services that
were running at cutover start. Once fencing begins, evidence and tombstones
remain in place so another process cannot silently revive a legacy writer.

The live database directory is private (`0700`), and the main database, WAL,
and SHM files must be owned single-link regular files with no group/world mode
bits. Exact schema validation hashes the normalized SQLite table/index DDL,
rather than accepting a database merely because expected names exist.

## Early activation gate

The installed candidate runs a read-only gate in `bin/hive` before LLM-wiki
reconciliation or any other startup mutation. With legacy state and no active
control plane, ordinary commands fail with `fleet_cutover_required`. The gate
permits only fleet migration, runtime status/resume, doctor, version inspection,
and genuinely fresh setup. It never creates or migrates the database.

## Tests

- `test/unit/commands/runtime_test.rb` covers typed status/resume output and
  corrupt-manifest refusal.
- `test/unit/runtime_control_plane/activation_gate_test.rb` covers inactive,
  incomplete, active, and pre-wiki gate ordering.
- `test/unit/runtime_control_plane/cutover_test.rb` covers validated token-usage
  import, disposable runtime reset, custom state roots, and crash-forward
  convergence across fencing, database, intent, and service boundaries.
- `test/unit/runtime_control_plane/maintenance_test.rb` covers idempotent
  service quiescence and restart intent without launcher mutation.

## Backlinks

- [[commands/migrate]] · [[commands/update]] · [[commands/doctor]] · [[state-model]]

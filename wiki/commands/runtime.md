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

Every successful JSON call emits a `hive-runtime-maintenance` envelope with the
action and typed result. Errors retain their runtime-control-plane code, action,
and details through the normal CLI error renderer.

## Status

`status` is read-only. It validates the immutable cutover manifest, the exact
SQLite schema and application identity when a database exists, installation
lineage, and activation epoch. A healthy database beside a missing, corrupt, or
identity-mismatched manifest is an error rather than an inferred active
installation.

The durable phases are:

- `ready`: services are quiesced, task authority is fingerprinted, and any
  legacy token-usage database has a validated immutable snapshot.
- `intended`: retired writers are fenced and the rebuilt SQLite database is
  installed; activation must converge forward.
- `active`: database identity and current services are active.

An incomplete result reports `hive runtime resume` as the action. Hive offers
no rollback, restore, or downgrade command for this irreversible transition.

## Resume

`resume` reopens the recorded manifest and continues from its durable phase. It
revalidates task fingerprints and the token-usage snapshot, installs the rebuilt
database idempotently, and publishes `active` only after the services recorded
as running at cutover start again. Once fencing begins, evidence and tombstones
remain in place so another process cannot silently revive a legacy writer.

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

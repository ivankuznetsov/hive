---
title: Irreversible fleet runtime cutover and activation gate
date: 2026-08-30
tags: [runtime-control-plane, sqlite, migration, activation, resume]
---

Hive now replaces the retired attempts-v4 recovery migration with one explicit,
offline, irreversible installation cutover. The package manager publishes the
candidate normally; Hive never renames package-owned launchers or preserves a
previous executable tree. A read-only gate runs before wiki reconciliation and
refuses ordinary candidate entry points until SQLite activation is complete.

Cutover stops managed services, rejects live owners, inventories and seals every
legacy runtime domain, installs path-shape fences for retired writers, validates
one closed SQLite database/payload candidate for the whole fleet, records
irreversible intent, activates, and restarts current services. Interruptions
after sealing retain immutable evidence and resume only forward.

`hive runtime` now exposes manifest-aware status and resume only. Fresh setup is
the explicit empty-database bootstrap path; normal runtime opens never create or
migrate. Previous-release Update reaches the candidate's interactive
confirmation contract, while non-TTY migration requires the exact
`hive migrate --all --yes` action. Backup, restore, downgrade, launcher custody,
and rollback branches from the earlier design were deleted.

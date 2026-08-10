---
title: Recovery v2-only cutover and dogfood runtime follow-ups
type: change
date: 2026-07-26
tags: [recovery, migration, attempts, daemon, babysitter, web]
---

Hive now has one recovery upgrade path instead of another compatibility layer.
`Hive::Recovery::Migration` moves the old attempt tree to `attempts/v2`,
rewrites retained attempt v1 records, archives final compatibility leases,
upgrades queued request/result documents, and records the completed cutover.
Explicit `hive migrate` plus daemon/bot startup own that mutation; a foreground
default store fails closed while v1 remains.
Runtime attempt and queue readers accept only their current schemas; the old
schema files, legacy backfiller, compatibility lease constructors, and
in-memory normalization branches were removed. Any live old-root attempt
(including compatibility ownership) or ambiguous old/current roots stop the
cutover safely so an old supervisor cannot recreate v1 after the move.

`hive migrate` also backfills a missing registered repository identity from the
current origin without overwriting an existing value. The PR babysitter skips
unresolved and explicitly local repository rows before GitHub polling, so local
benchmark registrations no longer create `gh` failures.

Managed web installation now gives a cold Rails service 40 health samples at
250 ms intervals before declaring `active_not_ready`; read-only web status
remains immediate.

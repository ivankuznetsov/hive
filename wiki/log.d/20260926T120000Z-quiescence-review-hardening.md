---
title: Harden quiescence recovery and custody proof
type: log
created: 2026-09-26
tags: [daemon, quiescence, runtime-control-plane, attempts]
---

- Quiesce and resume now settle abandoned pre-close reservations under both
  launch and writer fences. Failed resume reconciliation stays in its prior
  closed phase, and quiesce can rebind the same generation after a reboot or
  schema upgrade without reopening admission.
- Attempt-wrapper ownership survives root exit until an exclusive delegated
  cgroup proves descendant absence. Automatic detection rejects ambient
  cgroups, membership inventory is frozen and recursive, and unobservable
  members stay unresolved.
- Controller and migrator authority can only be minted while the exclusive
  writer fence is held. Admitted-worker cleanup is limited to one durable write
  per attempt and lost-attempt reconciliation uses that same bounded route.
- The operation deadline now begins before SQLite opens and is consumed across
  database and fence waits. Upgrade replacement checkpoints authoritative WAL
  first, legacy PID receipts reject dead or reused identities, and lifecycle
  output reasons are schema-enumerated.
- Quiescence results, finalization proof, process evidence, and finalization
  logic now have focused files; daemon activation shares the hardened runtime
  fence implementation. Scenario suites include an actual cross-process
  quiesce-versus-resume race.

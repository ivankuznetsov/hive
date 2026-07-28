# Harden module admission, execution, and migration recovery

- Authenticated detached module hooks now survive transport-environment
  scrubbing, bind directly to their module subject, and recover an admitted
  launch receipt after a crash before decision persistence. The one-off
  recovery migration projects retained v1/v2 task records into v3 before
  runtime readers open them.
- Migration transitions and module admission share one ownership lock,
  quiescence uses a transition-current attempt scan, and rollback requires a
  fresh shadow window before another cutover.
- Command targets validate bubblewrap during activation, expose reviewed
  filesystem grants instead of the host root, enforce closed or wildcard
  network modes, and redact granted secret values from bounded output.
  Packaged workflow targets remain activation-validated but execution-disabled
  until module-pinned admission and recovery are durable.
- The event ledger now maintains a recoverable event/schedule index and the
  daemon persists its drain cursor, avoiding retained-history rescans on idle
  ticks. The merged-PR producer supplies independent Architecture Patrol
  capture evidence; schedule-only decisions remain non-comparable.
- Module activation keeps recovery evidence through the fallible state commit;
  later cleanup is warning-only. Uninstalled tombstones may be reinstalled
  with a new watermark, and catalog rejection preserves caller-owned
  destinations.

**Pages:** [[modules/workflows]], [[modules/events]], [[modules/attempts]],
[[modules/patrol]]

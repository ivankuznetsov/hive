# 2026-09-25 — Daemon-independent quiescence coordination

- The runtime now has an installation-wide quiescence controller with the
  fixed 60% drain, 25% escalation, and 15% finalization phases.
- Ownership is checked before durable admission closure and rechecked after
  launch reservations settle under the exclusive launch fence. A refusal
  before closure is non-disruptive; a refusal or timeout after closure keeps
  the same generation quiescing.
- Registered processes are re-identified before TERM/KILL, interrupted
  attempts are recorded only after absence proof, and unresolved evidence is
  aggregated rather than dropped.
- Paused remains a database candidate until a checked SQLite FULL checkpoint,
  connection close, and atomic owner-private proof bind the installation,
  generation, lifecycle revision, mutation sequence, stopped inventory, and
  interruption set.
- Durable quiescence clamps daemon-child and attempt-worker shutdown before
  the finalization reserve. Ordinary daemon stop retains its configured grace.

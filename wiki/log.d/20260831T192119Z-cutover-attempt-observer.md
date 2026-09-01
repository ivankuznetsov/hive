---
title: Advance terminal observations across the SQLite cutover
tags: [runtime-control-plane, cutover, task-journal, projection, daemon]
---

The daemon's terminal-attempt observer still read and rebuilt each complete
task journal after the all-in cutover. Retained pre-activation records therefore
failed against the intentionally reset attempts table and left terminal
publication pending.

The observer now uses a valid authenticated checkpoint for idempotency and
commit-generation facts, validates only the appended suffix against SQLite,
and advances the derived checkpoint. Missing or invalid checkpoints retain the
strict full-replay behavior, and a restarted observer proves it does not append
the same terminal fact twice.

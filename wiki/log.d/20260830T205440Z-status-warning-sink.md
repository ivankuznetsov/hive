---
title: Capture all in-process status warnings
date: 2026-08-30
---

- Consolidated `Status#warn` on the shared warning emitter.
- Scoped the daemon's in-process task-graph build to one active warning sink,
  preserving nested task metadata, descriptor, completion-time, deprecated
  config, and managed workflow warnings that the retired subprocess previously
  captured from stderr.
- Added a real `StatusConsumer` regression proving nested warnings are returned
  in `Result#warning` without leaking to daemon stderr.

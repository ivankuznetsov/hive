---
title: Failed automatic advances converge through markerless recovery
date: 2026-08-31
tags: [daemon, attempts, recovery, idempotency, capacity]
---

**Problem:** The daemon assigned a fresh request id to every direct advance
scan. When a markerless stage command failed before changing task state, each
tick treated the new id as an explicit retry. An old broken row could therefore
consume every available attempt slot indefinitely and starve queued recovery
work.

**Action:** A daemon-owned advance for a row that still has no marker now
replays the latest failed terminal attempt for the unchanged semantic
generation. The dispatcher turns that replay into the existing locked
`markerless_stalled` repair: marker-driven tasks receive the ordinary
recoverable error marker and controller workflows receive a generation-bound
recovery request. Marked advances and explicit recovery requests retain fresh
retry semantics.

**Evidence:** Attempts tests prove a second automatic request replays one failed
attempt while a healer recovery request launches a successor. Daemon tests prove
the terminal replay writes the recoverable error, records the attempt-bound
stall event, and does not spawn a second worker.

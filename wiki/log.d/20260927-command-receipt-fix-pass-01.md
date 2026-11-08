---
date: 2026-09-27
title: Close command receipt review safety gaps
---

- Require authoritative per-effect reconciliation and live-owner fencing before
  a keyed command can resume or finalize after interruption.
- Restore durable command context in workers and keep answer bindings
  reconstructible without persisting their literal encoded values.
- Unify receipt byte accounting across admission, retirement, audit, preview,
  and pruning, including bounded administrative-batch retention.
- Make cold prune previews zero-write, classify real SQLite busy errors, and
  harden owner-only namespace selection and legacy owner-id enrollment.
- Derive the installation non-terminal cap from the measured byte envelope and
  keep compatibility proof checksums executable without committing a gem.

---
title: Keep restart baselines without a second locking protocol
type: change
date: 2026-09-05
---

Dispatch baselines retain their existing JSON shape, microsecond mtimes,
restart behavior, and failure diagnostics. The daemon already owns exclusive
writer custody, so the baseline store no longer creates or waits on a sibling
lock. Shared `Hive::AtomicFile` replaces the private tempfile/rename writer.
Both temporary-file naming conventions remain covered by stale-file cleanup.

Regression coverage proves that writes create no second lock, failed replacement
preserves the previous restart baseline, and controller restart behavior remains
intact. No daemon configuration, task state, or live service was changed.

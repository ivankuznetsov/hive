---
timestamp: 2026-06-30T11:05:00Z
title: Review fix stop-hook failures are bounded auto-recoverable
---

- `StaleAgentHealer` now treats `REVIEW_ERROR phase=fix reason=fix_failed message="claude stop hook did not signal completion"` as a narrow recoverable infrastructure failure.
- Generic `fix_failed` markers remain manual; the healer includes the stop-hook `message` in the guarded marker clear so stale rows cannot clear a different fix failure.

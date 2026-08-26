---
title: Status bounds per-task projection reads
type: log
date: 2026-08-23
---

**Changed:** Full status scans now consume a current per-task projection
checkpoint when its bounded journal and attempt-identity checks pass. Mutable
attempt state is refreshed and reprojected without replaying old journal
history. Appended journals and partial, stale, invalid, or unverifiable
checkpoints fall back to the unchanged authoritative full-journal reader.

**Why:** The 221-task local fleet held about 5.5 MB of task journals, and full
status replayed 141 of them on every scan because durable attempt state had
advanced after snapshot publication. This made work grow with retained
history, not only with each task's current small artifacts.

**Verification:** Five exact-fleet scans averaged 2.81 seconds on the parent
and 2.01 seconds with bounded task reads, a 28.5% reduction. Normalized full
JSON output was byte-identical. Focused tests cover unchanged checkpoints,
mutable terminal attempts, appends, same-size source changes, forged attempt
identity, and authoritative fallback.

---
title: Reuse the daemon full graph for concise status
type: log
date: 2026-08-24
---

**Changed:** Full daemon status results now retain their validated source
payload and publish it once in a dedicated owner-private atomic cache. Bare
`hive status` and `--operational` reuse a current tick-bound payload instead of
rescanning every task. Bounded changed-task reads cannot replace the full
cache, and compatibility JSON, full, archive, and diagnosis modes remain fresh.
The large payload is not embedded in scheduler phase records, so web, watch,
and other operational-snapshot readers do not parse or retain it.

**Safety:** The cache has its own short deadline and source tick sequence. A
same-tick graph can join scheduler decisions directly; a prior-tick graph used
during an in-progress scan keeps the scheduler unavailable, while absent,
malformed, generation-mismatched, project-mismatched, or expired cache data
falls back to a fresh scan. Cache publication failure cannot suppress the
small scheduler snapshot. The human heading and JSON source expose cache age
and provenance; `hive status --full` forces a fresh human read.

**Measured:** On the live 18-project payload, the cached graph is 1.50 MB. A
single atomic cache write took 4.60 ms, a validated opt-in read averaged 10.44
ms, and the operational projection averaged 20.03 ms. The small scheduler
snapshot remains independent. The former fresh command path spent about 2.8
seconds of CPU-heavy task scanning.

**Refreshed pages:**
- [[commands/status]]
- [[modules/daemon]]

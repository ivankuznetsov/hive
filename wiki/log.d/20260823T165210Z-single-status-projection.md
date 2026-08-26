---
title: Daemon full ticks use one status projection
type: log
date: 2026-08-23
---

**Changed:** Removed the daemon's duplicate end-of-tick full `hive status`
projection. Scheduler decisions now publish from the tick's authoritative
source frame, while operational consumers fail closed unless their task graph
was sampled after snapshot completion and still matches every scheduler join
field.

**Why:** On the local 221-task dogfood fleet, each full status projection costs
about 2.9 seconds of CPU-heavy work. The second projection repeated that cost
every 30 seconds even though later operational status already rejoined task
identity and policy fields.

**Verification:** Focused dispatcher, operational snapshot, and operational
status tests pin one full status fetch per tick, temporal race rejection,
subsecond ordering, malformed-window rejection, and the unchanged field-level
join contract. An exact-branch dry-run completed three 221-task ticks with one
status fetch each: 18.91 seconds cold, then 12.72 and 12.94 seconds steady,
with no fatal, snapshot, or tick errors.

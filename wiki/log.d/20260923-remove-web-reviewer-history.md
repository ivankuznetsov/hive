---
title: Remove historical reviewer routes from Hive Web
date: 2026-09-23
---

Hive Web omits historical plan-review routes from task detail and from active,
completed, and persisted status frames. The shared status source applies Web's
display projection before retaining its payload and rows. Existing saved frames
are compacted on read. Retry keeps only the latest eligible review attempt ID,
alongside the existing exact review observation fields. Findings, review status,
operator decisions, and current audit artifacts remain available. Native status
and durable review records retain route history.

See [[commands/web]].

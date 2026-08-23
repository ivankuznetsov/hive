---
title: Bound slow daemon full-scan duty cycle
type: change
date: 2026-08-23
tags: [daemon, status, performance, scheduling]
---

The daemon now starts `poll_interval_sec` when a full repair scan completes,
instead of when it begins. A slow periodic scan therefore cannot make its
periodic replacement immediately overdue, even when retained task growth makes
the scan itself exceed 30 seconds. Previously, any periodic scan longer than
the interval could pin the dispatcher in continuous fleet-wide projection
work. Ancillary completion can still request an immediate full follow-up scan
by design.

Changed-task ticks still do not move the full-repair deadline. A regression
models a 45-second scan and proves the next full scan is due 30 seconds after
completion, not immediately.

---
title: Remove spent Architecture Patrol progress cutover
type: change
date: 2026-08-28
---

Removed the one-time Architecture Patrol reconciler-progress v1 deletion from
`hive migrate` after the dogfood cutover completed. The daemon and progress
store now expose only the current v2 continuation contract; unsupported state
continues to fail closed through quarantine.

---
title: Bound daemon fast ticks to changed tasks
type: change
date: 2026-08-23
tags: [daemon, status, performance, dependencies]
---

The daemon's one-second probe now stats a rotating batch of at most 64 tracked
state files and refreshes only exact changed `project:slug` rows. Child exits
feed the same bounded path. Dependency-bearing rows fail closed until the next
authoritative full dependency scan, so the fast path needs no dependency graph
or transitive traversal. Bounded response errors or identity mismatches leave
cached daemon state untouched. The 30-second full tick remains unchanged as
repair for global
schedulers, task inventory, dependency release, metadata/config changes,
archive counts, and operational snapshots; fast ticks never postpone it.

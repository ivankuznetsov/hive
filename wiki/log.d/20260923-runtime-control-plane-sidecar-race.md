---
title: Tolerate transient SQLite sidecar disappearance during custody checks
date: 2026-09-23
---

Runtime control-plane custody validation now tolerates a SQLite WAL or SHM
sidecar disappearing between its presence check and `lstat`. Existing sidecars
remain subject to the same owner, mode, type, link-count, and symlink checks;
the primary database remains strict. The regression test pins the exact
existence-to-`lstat` race observed under concurrent Patrol budget testing.

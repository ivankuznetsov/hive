---
title: Attempt storage now rejects redirected managed paths
date: 2026-07-30
tags: [attempts, durability, filesystem, recovery]
---

The durable-attempt store now revalidates its managed directories before
access, rejects symlinked record and lock leaves, and preserves root
containment for per-attempt recovery outputs. Attempt stream readers and
writers apply the same no-follow policy. Corrupt or replacement links fail
closed before Hive changes permissions or reads or writes redirected state.
Malformed stream-log parents, including non-directories and symlink loops, now
return an empty replay instead of propagating a filesystem read error.

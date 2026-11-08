---
title: Preserve digest preparation ownership across garbage collection
date: 2026-09-10
---

Digest delivery now retains the preparer token while its owning fiber is alive.
A weak-key map prevents garbage collection from losing the token between
preparation and sending or resuming after missing credentials. Forced-GC
regressions cover both paths. See [[modules/daily-digest]].

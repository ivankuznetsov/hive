---
title: Restore saved web status across restarts
date: 2026-09-16
tags: [web, status, loading, cache]
---

Web restores an owner-private, bounded, registry-scoped saved status snapshot
and immediately refreshes it in the background when the first subscriber
connects. Saved task labels and filters remain useful, with a dated neutral
notice and disabled state-dependent controls until fresh data arrives.
Invalid caches fall back to normal cold loading; failed refreshes retain the
last good display and failed writes leave the previous atomic cache intact.
See [[commands/web]]. Focused feed/store/target resolver tests, Rails integration,
and desktop/mobile browser coverage exercise restore, delayed refresh, failure,
and live replacement. Full fleet scan cadence remains unchanged.

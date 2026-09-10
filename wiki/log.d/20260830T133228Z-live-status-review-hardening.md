---
title: Live-status review hardening
date: 2026-08-30
tags: [web, turbo, action-cable, lifecycle, review]
---

The stage-6 fix pass closed the remaining dedicated-status ownership gaps.
Application retries now re-register the Turbo stream listener and preserve a
same-URL catch-up latch, socket capture survives throwing connection opens and
reopens, stale unconfirmed registrations retire transport-first, and repeated
supersession force-retires the older pending predecessor before another
transport is allocated. Warning queues restore through escaping successor
setup, and stale setup rejections retire and warn consistently.

The focused system suite now contains 22 cases. It restores a real
`StatusChannel#catch_up` observation after retry, makes pre-confirmation lease
counts exercise the actual broadcaster lifecycle, proves a real unconfirmed
lease returns to zero through bounded transport cleanup, keeps callbacks after
that timeout inert, and counts dedicated consumers across Turbo navigation.
The ownership docs now state that cross-URL permanent-element moves replace the
transport and therefore pay a fresh WebSocket plus Action Cable handshake.

---
title: Keep cold status scans off the HTTP request thread
module: web
tags: [status, performance, turbo, action-cable]
---

The live dogfood status page spent 4.1 seconds in `StatusController#index`
while its view rendered in only 36 ms; `/health` remained at roughly 1-2 ms and
the web process idled at 0.1% CPU. `StatusBroadcaster` now renders the latest
published `StatusFeed` state without scanning. On a cold process it returns the
existing loading surface immediately, then the first accepted Turbo/Cable
subscription performs the fleet scan on the broadcaster thread and publishes
the real snapshot. The loading token stays current until that publication
succeeds, so confirmed-channel catch-up cannot race it into a refresh loop.

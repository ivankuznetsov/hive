---
title: Keep status layout stable while loading
---

Moved freshness warnings inside the status main column so a warning cannot
occupy the project rail grid slot. Cold Board and Grid renders use a neutral
loading panel with a reduced-motion-aware indicator; actual failed refreshes
retain the existing warning and unavailable state. Integration coverage checks
both initial views and warning containment.

On mobile, the loading panel is compact and appears above the composer. Browser
coverage checks its height and position in the initial viewport.

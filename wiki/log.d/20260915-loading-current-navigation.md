---
title: Preserve current navigation when integrating loading polish
date: 2026-09-15
---

The loading and mobile navigation changes now preserve the Honeycombs entry and
Digest link on current main. The mobile project selector uses the same
`status_filter_path` helper as the desktop rail, retaining current task filters.
The mobile workflow regression opens the menu before checking all capabilities
and still checks viewport overflow with enlarged text.

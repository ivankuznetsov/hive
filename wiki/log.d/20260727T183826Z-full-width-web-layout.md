---
title: Make Hive web use the full viewport
date: 2026-07-27
tags: [web, layout, responsive, kanban]
---

- Removed the 1040px cap from the shared application and navigation shells.
  Fluid edge gutters now preserve breathing room without wasting large-screen
  space.
- The status project rail scales within a bounded range and leaves all
  remaining width to the composer, task grid, and board.
- Kanban tracks keep a comfortable minimum, expand evenly when the viewport
  has room, and retain their existing contained horizontal scroll on smaller
  screens.
- Playwright system coverage pins both the full-width desktop shell and the
  growing Kanban tracks alongside the existing mobile-containment proof.

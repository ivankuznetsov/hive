---
title: Avoid the system-test live-grid race
type: fixed
date: 2026-07-18
---

The Hivebox pipeline system test now visits the task route through the folder
it just created instead of retaining and clicking a `.task-row` while Turbo can
replace the grid. This applies the existing live-grid synchronization rule to
the remaining system-test path and removes its one-use row helper.

---
title: Show completed tasks on normal project boards
---

- Merge the selected project's archive projection into normal Board and Grid
  rendering, including completed state counts and read-only task links.
- Expand populated completed columns on project boards.
- Scope project Done/Archive reads before scanning; cache for one minute with
  immediate invalidation on stage moves. Keep the active fleet feed unchanged.
- Add normal-route architecture completion, cache invalidation, and browser
  navigation regression coverage. Prior coverage tested only the separate Done
  page and missed the normal project board.

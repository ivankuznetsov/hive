---
title: Make Hive Web workflow acceptance deterministic across CI browsers
created: 2026-07-19T01:00:00Z
tags: [web, workflow, testing, playwright, coverage]
---

- Added root-suite coverage for Hivebox's workflow lifecycle adapter, including
  exact install/update candidate rebinding and selected-generation checks for
  update/remove.
- Made the workflow-authoring browser path choose its target project explicitly,
  matching the real multi-project experience instead of depending on test order.
- Tightened the five-item mobile navigation spacing so every capability remains
  visible across Chromium/font metric differences without page overflow.

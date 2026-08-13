---
title: Remove unused task display-label facade
date: 2026-08-13
---

- Removed the uncalled `Hive::Task#display_label` convenience reader. Status
  surfaces already apply their own `display_name`-or-slug presentation fallback.
- Kept the underlying `display_name` and `slug` readers and their sidecar
  coverage unchanged.

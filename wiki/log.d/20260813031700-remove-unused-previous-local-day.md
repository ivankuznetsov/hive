---
title: Remove unused previous-local-day helper
date: 2026-08-13
---

- Removed the uncalled `Hive::LocalDateWindow.previous_local_day` convenience
  helper. Runtime date-window checks continue through `local_today` and
  `on_local_date?`.

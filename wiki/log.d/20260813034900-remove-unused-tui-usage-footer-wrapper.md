---
title: Remove unused TUI usage-footer wrapper
date: 2026-08-13
---

- Removed the private, uncalled `Hive::Tui::BubbleModel#usage_footer_line`
  wrapper. Live footer rendering continues through `default_footer`, which
  derives the same cached usage aggregate and renders it responsively.
- Retargeted task, project, and global usage-scope assertions to the live
  default-footer path.

---
title: Share TUI viewport calculation
type: changed
date: 2026-07-19
---

Project and task panes now use `Hive::Tui::Views::Format.viewport_start` for
their identical cursor-following scroll-window calculation. Pane content,
selection clamping, visible rows, padding, narrow-terminal behavior, and
rendered frames are unchanged.

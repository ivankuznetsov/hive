---
title: Honor Ctrl+C across TUI modes
type: change
created: 2026-07-30
tags: [tui, keyboard, signals]
---

- Routed Bubble Tea's decoded `KEY_CTRL_C` directly to the application
  termination message before mode-specific key handling. Ctrl+C now exits
  cleanly from the grid, overlays, and editable prompts while detached workflow
  agents continue running.

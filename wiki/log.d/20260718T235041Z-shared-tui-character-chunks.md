---
title: Share TUI character chunking
type: changed
date: 2026-07-18
---

The new-idea composer and read-only idea preview now use
`Hive::Tui::Views::Format.character_chunks` for their identical fixed-width
character slicing. Empty-buffer rows, cursor placement, attachment rendering,
preview wrapping, and truncation behavior are unchanged.

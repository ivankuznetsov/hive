---
date: 2026-08-26
slug: shared-tui-ansi-aware-prefix-truncation
---

- `Hive::Tui::Views::Format.truncate`/`take_cells` are now ANSI-aware: escape
  sequences carry zero visible width in `display_width`, pass through cuts
  intact, and a cut that strands an open SGR sequence gets a reset appended.
  This fixes the new-idea project picker's reverse-video cursor row, which was
  styled before the final `rows.map { truncate }` pass and previously had its
  escape bytes counted as cells and its reset sliced off.
- The cut is additionally a strict prefix cut: once a visible grapheme does
  not fit the remaining budget, an `exhausted` flag stops all further visible
  consumption across subsequent text tokens — mid-line SGR sequences can no
  longer let text leak past a non-fitting wide grapheme (e.g. `a🤖bold…`
  truncating to `ab…` instead of `a…`).
- Covered by `test/unit/tui/views/format_test.rb` (width measurement, reset
  preservation, stranded-style closure, cross-token prefix semantics,
  padding by visible width) and a picker-level styled-cursor-row regression
  in `test/unit/tui/views/new_idea_project_picker_test.rb`.

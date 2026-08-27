# TUI archive pane and filter prompt switched to cell-aware width math

- **Date:** 2026-08-16

## What changed

`lib/hive/tui/views/archive_pane.rb` and `lib/hive/tui/views/filter_prompt.rb`
computed widths with String's column-naive character counts
(`String#ljust`, `String#rjust`, `String#length`) instead of the cell-aware
`Format` helpers that exist for exactly this purpose. Wide (CJK) characters
occupy two terminal cells, so:

- Archive rows padded `"项目"` with `.ljust(18)` produced a 20-cell project
  column, shifting the age column right relative to ASCII rows.
- `FilterPrompt` slid its visible window by character count; a 40-char CJK
  buffer rendered as 80 cells and overflowed a 40-column terminal, while a
  30-char (60-cell) buffer never slid because its character count fit the
  budget.

Fixes:

- `ArchivePane.render_row` now pads via `Format.ljust_cells` /
  `Format.rjust_cells` (which also subsume the explicit truncation).
- `FilterPrompt.render` budgets by `Format.display_width` and slides via a new
  public `Format.tail_cells(label, max_width)` helper — the cell-aware tail cut
  complementing the private `take_cells`.
- Regression tests in
  `test/unit/tui/views/{archive_pane,filter_prompt}_test.rb` pin age-column
  alignment across ASCII/wide rows and cell-bounded sliding windows; all three
  fail against the previous character-count implementations.

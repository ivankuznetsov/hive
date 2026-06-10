## [2026-06-08T12:00:00Z] tui — scrollable help overlay

**Action:** Updated the TUI help overlay so the `?` screen is height-bounded, word-wraps binding descriptions, and scrolls instead of overflowing the alt-screen on short terminals. Help now keeps a fixed footer, renders a right-edge scrollbar when content overflows, re-clamps its offset on resize, and shows a centered "terminal too small" fallback below 10x40. Keyboard scrolling uses Up/Down, `j`/`k`, PgUp/PgDn, Home/End, and `g`/`G`; mouse wheel events scroll help by three lines after enabling Bubbletea mouse cell reporting. Explicit close keys are `q`, `Esc`, and `?`; unrelated keys no-op instead of dismissing.

**Refreshed pages:**
- [[commands/tui]]

## [2026-06-10T09:31:27Z] wiki — audit scrollable TUI help overlay coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `bd549d0c` documented the scrollable `hive tui` help overlay. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "tui scrollable help overlay page down page up"` returned no indexed hits, so verification used the committed diff plus direct source and test reads. Inspected `wiki/commands/tui.md`, the committed log fragment, `lib/hive/tui/views/help_overlay.rb`, `lib/hive/tui/key_map.rb`, `lib/hive/tui/update.rb`, `lib/hive/tui/bubble_model.rb`, `lib/hive/tui/app.rb`, `lib/hive/tui/messages.rb`, and focused TUI unit tests. Confirmed the wiki's command coverage matches source behavior: the overlay is height-bounded, wraps content, scrolls via keys and mouse wheel, reclamps on resize, uses explicit close keys, no-ops unrelated keys, and has a 10x40 fallback. Clarified [[commands/tui]] test coverage and recorded the remaining uncertainty in [[gaps]]: no checked-in real-terminal smoke artifact proves the full help overlay path. Page coverage did not change, so [[index]] was left unchanged. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/tui]]
- [[gaps]]

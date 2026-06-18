---
date: 2026-06-16
slug: clipboard-capture-coverage-audit
pages: [testing, gaps]
---

Audited post-commit wiki coverage after commit `5389920e`
(`test(tui): stabilize clipboard capture coverage`) changed
`test/unit/tui/clipboard_test.rb`, [[testing]], and a prior wiki log fragment.
Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]],
[[gaps]], and recent [[log]] entries first. `qmd search "clipboard capture TUI
coverage fixture"` only surfaced older TUI image-input history, and the
configured master wiki path had only a general array-form subprocess lesson, so
verification used the committed diff plus direct reads of
`lib/hive/tui/clipboard.rb`, `test/unit/tui/clipboard_test.rb`,
[[commands/tui]], [[testing]], and [[gaps]].

Confirmed the production `Hive::Tui::Clipboard::DefaultShim.capture3` did not
change; only the unit test's generic stdout/stderr and timeout subprocess
fixture moved from nested `RbConfig.ruby` to temporary executable shell scripts
so coverage-injected `RUBYOPT` cannot dominate unrelated timeout assertions.
Updated [[testing]] to add explicit `tui/clipboard_test.rb` unit-suite coverage,
and recorded in [[gaps]] that no checked-in artifact proves the hosted Ruby
3.4.9 coverage job passed after `5389920e` or that the real OS clipboard probes
were live-smoked after this test-only fixture change. Page count stayed 80, so
[[index]] did not need a page-list update. Did not run `qmd update` or
`qmd embed`.

---
slug: claude-tmux-ready-detector-refresh
created: 2026-06-30T16:30:00Z
---

**Action:** Refreshed main-checkout wiki coverage for branch `fix-claude-tmux-ready-detector-260629-50cc` after its finalize backstop commit touched wiki files. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "claude tmux ready detector packaging detector review limit text threading"` returned no indexed hits. Inspected the committed wiki diff plus current `lib/hive/claude_launcher.rb`, `test/unit/claude_launcher_test.rb`, `hive.gemspec`, `test/unit/gemspec_test.rb`, `test/integration/gem_package_scripts_test.rb`, and existing wiki pages. Updated the shared Claude/tmux ready-prompt docs for Claude Code 2.1.179 separator/caret/footer prompt chrome, Unicode separator spaces, and the stricter bypass-permissions footer check; carried forward the local-gem live replay gap using the branch slug rather than a raw commit reference. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/agent]]
- [[stages/brainstorm]]
- [[testing]]
- [[gaps]]

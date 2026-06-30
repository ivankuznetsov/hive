---
slug: claude-tmux-packaging-detector-refresh
created: 2026-06-30T15:30:00Z
---

**Action:** Refreshed main-checkout wiki coverage for branch HEAD after it
documented the local validation path for unreleased Claude tmux launcher-script
packaging fixes. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]],
[[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search
"Claude tmux packaging detector ready"` returned no indexed hits, and the
configured master wiki path did not exist in this checkout. Inspected the
committed diff plus current `hive.gemspec`, `lib/hive/claude_launcher.rb`,
`lib/hive/commands/daemon.rb`,
`lib/hive/commands/daemon/service_installer.rb`,
`test/unit/gemspec_test.rb`, and
`test/integration/gem_package_scripts_test.rb`. Copied the operating guidance
into the global main wiki and recorded that source/tests prove the script
packaging contract, but no in-tree artifact proves a locally built gem replayed
the affected Claude tmux task to `WAITING` or later. Did not run `qmd update`
or `qmd embed`.

**Refreshed pages:**
- [[operating]]
- [[gaps]]

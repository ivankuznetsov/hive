## [2026-06-12T10:11:17+01:00] wiki — audit Claude model/effort command and agent surface

**Action:** Refreshed command/API and executable-wrapper wiki coverage after commit `8d180e2e` added project-global `claude.model` / `claude.effort` pins for hive-launched Claude sessions. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "claude model effort config init prompt agent spawn tmux wrapper"` surfaced the existing gaps/log context but no fuller project page. Inspected the committed diff plus current `lib/hive/config.rb`, `lib/hive/agent.rb`, `lib/hive/stages/base.rb`, `lib/hive/claude_launcher.rb`, `lib/hive/scripts/interactive_claude_wrapper.sh`, `lib/hive/commands/init.rb`, `lib/hive/commands/init/prompts.rb`, `templates/project_config.yml.erb`, `schemas/hive-init.v1.json`, and focused init/agent/launcher tests.

Documented that `hive init` now asks two additional Claude questions after permission mode, that `hive-init.v1` carries `claude_model` / `claude_effort` in the nested `answers` object rather than as top-level fields, and that `Hive::Config.claude_cli_flags` feeds both the headless `Hive::Agent` argv and the tmux wrapper. Updated ADR-030 in [[decisions]] so the global Claude launch decision now records the model/effort follow-up instead of stopping at mode and permission mode. Corrected the earlier fragment so it no longer claims branch-side web questionnaire/task-page changes or links to a missing `commands/web` page. Recorded the remaining uncertainty: argv wiring is unit-pinned, but no in-tree live Claude Code smoke artifact proves `--model default` or explicit `--effort` values against the installed CLI. Page coverage count stayed 76; [[index]] was updated for metadata/TLDR only. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands/init]]
- [[decisions]]
- [[modules/agent]]
- [[modules/config]]
- [[testing]]
- [[gaps]]
- [[index]]
- [[log]]

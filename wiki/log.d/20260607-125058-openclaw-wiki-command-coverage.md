## [2026-06-07T12:50:58Z] wiki — refresh OpenClaw wiki-command coverage

**Action:** Refreshed wiki planning/documentation coverage after commit `b47231e8` extended the OpenClaw `/hive` skill and focused tests for the `hive wiki compile-log` surface. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "openclaw hive wiki compile-log fragments slash command"` and the configured master wiki path produced no relevant prior guidance. Verified the committed diff plus current `openclaw/skills/hive/SKILL.md`, `openclaw/README.md`, `lib/hive/commands/wiki.rb`, `lib/hive/wiki_log.rb`, `test/integration/wiki_command_test.rb`, `test/unit/openclaw_skills_test.rb`, [[commands/wiki]], [[commands]], [[operating]], and [[testing]]. Updated wiki command coverage for the OpenClaw `/hive wiki compile-log --check` path, the fragment-first policy, legacy-entry/template-prose behavior, focused command/OpenClaw tests, the representative OpenClaw source map, and the remaining lack of a live OpenClaw invocation artifact. Page count stayed 75, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[commands/wiki]]
- [[commands]]
- [[operating]]
- [[testing]]
- [[gaps]]

## [2026-06-05T22:15:00Z] wiki — fragment-based changelog compilation

**Action:** Added `hive wiki compile-log`, `Hive::WikiLog`, and the `wiki/log.d/*.md` fragment flow so concurrent PRs can record wiki updates without all editing the hot `wiki/log.md` tail. Updated managed llm-wiki bootstrap prompts/context, checked-in AGENTS/CLAUDE guidance, and the current generated `.llm-wiki/*.sh` scripts to ask agents for fragments instead of direct compiled-log edits in feature PRs, initialized new projects with `wiki/log.d/.gitkeep`, documented the command, and added compiler/CLI/init coverage. Review follow-ups tightened legacy-body extraction so fresh wiki template prose is not preserved as a bogus changelog entry and added the OpenClaw `/wiki` skill surface for the new Thor command.

**Refreshed pages:**
- [[commands/wiki]]
- [[index]]
- [[testing]]

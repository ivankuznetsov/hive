## [2026-06-10T12:18:20Z] hivebox — refresh web command and API surface coverage

**Action:** Refreshed LLM wiki command/API coverage after commit `22b1f796` documented the Hivebox web workflow and added `docs/notes/hivebox-agent-oauth-relay.md`, the manual-gated Playwright contract, [[commands/web]], and `/hive web` OpenClaw coverage. Read `AGENTS.md`, `.llm-wiki/config.json`, [[index]], [[architecture]], [[decisions]], [[gaps]], and recent [[log]] entries first; `qmd search "hivebox web agents oauth relay"` and the configured master wiki path had no extra matching context. Inspected the committed diff plus current `lib/hive/commands/web.rb`, `lib/hive/web/**`, `lib/hive/config.rb`, Docker packaging, OpenClaw skill text, and focused `test/unit/web/**` / `test/e2e/hivebox_happy_path.spec.js` coverage. Updated docs so Hivebox intervention is recorded as a brainstorm-answer write, status/log SSE streams are bounded and shared, GitHub/agent auth boundaries match source, Docker supervisor behavior is covered, and missing live provider/Docker smoke plus stale README/FAQ wording remain explicit gaps. Page coverage count stayed 76, so [[index]] did not need a catalog update. Did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[architecture]]
- [[commands]]
- [[commands/web]]
- [[modules/config]]
- [[testing]]
- [[gaps]]
- [[log]]

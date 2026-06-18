## [2026-06-15T22:22:40Z] wiki — refresh agent-limit, finalize, and review triage coverage

**Action:** Refreshed LLM wiki coverage after inspecting recent `main` history through
`7f088c48` and the current source files changed by commits `118ed2fd` and
`7f088c48`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`,
[[index]], [[gaps]], and recent [[log]] / `wiki/log.d` entries first. Ran
`qmd search "AgentLimit finalize merged PR triage timeout budget digest patrol
dry-run GIT_EXEC_PATH"` and searched the configured main wiki path
`/home/asterio/wikis/master/wiki` plus the default cross-project wiki paths
that exist; no Hive-specific cross-project guidance matched the new
AgentLimit/finalize/triage changes.

Verified `lib/hive/agent_limit.rb`, `lib/hive/agent.rb`,
`lib/hive/stages/finalize.rb`, `lib/hive/stages/review/triage.rb`, and the
focused tests in `test/unit/agent_limit_test.rb`,
`test/integration/run_finalize_test.rb`, and
`test/unit/stages/review/triage_test.rb`. Updated [[modules/agent]] so
provider-limit classification documents raw-stream limit capture and the
usage-qualified limit pattern that avoids UI-feature false positives. While
checking test discovery, found the new AgentLimit UI-feature/time-window
assertions below a `private` marker; a standalone Minitest check showed private
`test_*` methods are not runnable, so [[testing]] and [[gaps]] record that as a
coverage gap rather than confirmed runnable coverage. Updated
[[stages/finalize]] for the direct already-merged PR short-circuit
(`COMPLETE merged=true`, no body-refresh agent, no `summary.md`). Updated
[[stages/review]] for the `review_triage` fallback budget/timeout values
matching `Config::DEFAULTS` (75 / 1800), refreshed [[testing]] coverage rows,
carried the remaining live-smoke uncertainty into [[gaps]], and refreshed
[[active-areas]] with the latest inspected commits.

No page coverage changed, so [[index]] did not need a page-list update. Did not
edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[modules/agent]]
- [[stages/finalize]]
- [[stages/review]]
- [[testing]]
- [[gaps]]
- [[active-areas]]

## [2026-06-17T22:23:12Z] wiki — audit current LLM wiki refresh coverage

**Action:** Refreshed the LLM wiki state by auditing the existing local wiki
edits and recent `main` history through `0d0cac16`. Read
`.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent
compiled [[log]] headings, and the latest `wiki/log.d` fragments first.
`qmd search "AgentLimit finalize merged PR triage timeout budget digest patrol
dry-run GIT_EXEC_PATH web agents auth codex device flow reviewer findings
transcript tmux paste"` surfaced the local refresh fragment and updated project
pages. Searched the configured main wiki path `/home/asterio/wikis/master/wiki`
and checked the default cross-project paths; only the configured master path
existed, and it had no relevant Hive-specific guidance for the current source
changes.

Inspected recent git history and the changed source/test files for the June 16
changes: `lib/hive/web/agents_auth.rb`,
`web/app/controllers/agents_controller.rb`,
`web/app/views/agents/index.html.erb`,
`lib/hive/reviewers/codex_review.rb`, `lib/hive/tmux_runner.rb`,
`lib/hive/stages/finalize.rb`, `lib/hive/agent_limit.rb`,
`lib/hive/stages/review/triage.rb`, plus focused tests under
`test/unit/web/`, `web/test/integration/`, `test/unit/reviewers/`, and
`test/unit/agent_limit_test.rb`. Verified the current local wiki edits cover
Codex `--device-auth`, operator-ward Agents-page polling, PTY output scrubbing,
URL sanitization, favicon assets, native Codex review transcript trimming,
tmux prompt-settle polling before Enter, finalize already-merged short-circuit,
stale rebase-duplicate resync, triage fallback defaults, and the AgentLimit
false-positive test discovery caveat.

No page coverage changed during this audit, so [[index]] did not need a
page-list update. [[gaps]] already records the remaining uncertainty for live
provider/Docker Agents-page login, live native Codex-review transcript trimming,
live Claude/tmux large-prompt settle, and private non-runnable AgentLimit
assertions. Did not edit compiled [[log]], and did not run `qmd update` or
`qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[commands/web]]
- [[decisions]]
- [[gaps]]
- [[modules/agent]]
- [[modules/reviewers]]
- [[stages/brainstorm]]
- [[stages/finalize]]
- [[stages/review]]
- [[testing]]

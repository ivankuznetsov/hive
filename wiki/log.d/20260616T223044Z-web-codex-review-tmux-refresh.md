## [2026-06-16T22:30:44Z] wiki — refresh web login, native Codex review, tmux submit, and finalize coverage

**Action:** Refreshed LLM wiki coverage after inspecting recent `main` history
through `0d0cac16`. Read `.llm-wiki/config.json`, `AGENTS.md`, `CLAUDE.md`,
[[index]], [[gaps]], recent [[log]] entries, and `wiki/log.d` entries first.
`qmd search "AgentLimit finalize merged PR triage timeout budget digest patrol
dry-run GIT_EXEC_PATH web agents auth codex device flow reviewer findings
transcript tmux paste"` returned no results. Searched the configured main wiki
path `/home/asterio/wikis/master/wiki` and the default cross-project wiki paths
that exist; only the configured master path existed, and it had no relevant
Hive-specific guidance.

Started from existing local wiki edits and
`wiki/log.d/20260615T222240Z-agent-finalize-review-refresh.md`, which already
covered `118ed2fd` / `7f088c48` AgentLimit, finalize already-merged PR, and
review-triage default fallback behavior. Extended the refresh across the newer
June 16 changes:

- `5c645734`, `b08703a3`, `c5cd70a9`, `c75f4039`, `70e6ff14`, and `b370e7c3`
  in `lib/hive/web/agents_auth.rb`, `web/app/controllers/agents_controller.rb`,
  `web/app/views/agents/index.html.erb`, `web/app/views/layouts/application.html.erb`,
  and focused web/unit tests. Updated [[decisions]] ADR-035 and [[commands/web]]
  for Codex `--device-auth`, operator-ward Codex/gh polling, Claude paste-back,
  PTY output scrubbing, URL sanitization that splits adjacent URLs, and
  favicon/icon assets.
- `0d0cac16` in `lib/hive/reviewers/codex_review.rb` and
  `test/unit/reviewers/codex_review_test.rb`. Updated [[modules/reviewers]] and
  [[stages/review]] so the native Codex reviewer documents dropping the middle
  exec/thinking/codex transcript before triage.
- `f25896a2` in `lib/hive/tmux_runner.rb` and `test/unit/tmux_runner_test.rb`.
  Updated [[stages/brainstorm]] and [[testing]] so tmux prompt submit is
  documented as pane-tail settle polling before Enter, not a fixed delay.
- `7b17bfd6` in `lib/hive/stages/finalize.rb` and
  `test/integration/run_finalize_test.rb`. Updated [[stages/finalize]] for the
  patch-identical stale rebase duplicate resync path and the guardrail that
  genuine local-only commits still become `ERROR reason=unpushed_commits`.

Refreshed [[active-areas]] with the latest inspected commits. Updated [[gaps]]
with dated uncertainty for live-provider/Docker Agents-page login, live native
Codex review transcript trimming, and live Claude/tmux large-prompt settle
evidence. Page count stayed 80, so [[index]] did not need a catalog update.
Did not edit compiled [[log]], and did not run `qmd update` or `qmd embed`.

**Refreshed pages:**
- [[active-areas]]
- [[commands/web]]
- [[decisions]]
- [[gaps]]
- [[modules/reviewers]]
- [[stages/brainstorm]]
- [[stages/finalize]]
- [[stages/review]]
- [[testing]]

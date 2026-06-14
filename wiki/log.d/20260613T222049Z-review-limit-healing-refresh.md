---
date: 2026-06-13
slug: review-limit-healing-refresh
pages: [active-areas, stages/review, modules/daemon, state-model, testing, gaps]
---

Post-commit LLM-wiki refresh after commit `b6bba5d6` changed
`lib/hive/stages/review.rb` and `test/integration/run_review_test.rb` for
review-phase provider-limit recovery. Read `.llm-wiki/config.json`,
`AGENTS.md`, `CLAUDE.md`, [[index]], [[gaps]], recent compiled [[log]] entries,
and recent `wiki/log.d/` fragments first. Searched the configured
`main_wiki_path` (`/home/asterio/wikis/master/wiki`) for usage-limit,
`limits_reached`, triage, and fix-phase terms before editing project pages; no
project-relevant master-wiki guidance was found. The other default
cross-project wiki paths did not exist. After the edits, a bounded read-only
`qmd search "review limits_reached triage fix provider limit"` surfaced the
newly refreshed pages plus existing review/agent context, with no additional
stale project page found.

Inspected recent git history and the `b6bba5d6` diff. The code now routes
triage and fix phase spawn failures through `mark_review_phase_failure`: when
the captured error text matches `Hive::AgentLimit.limit_reached?`, Hive writes
`REVIEW_ERROR phase=<triage|fix> reason=limits_reached retry_after=<iso8601>`
so `Hive::Daemon::StaleAgentHealer` can clear it after the existing cooldown;
ordinary non-limit failures still write terminal `triage_failed` /
`fix_failed`. `test/integration/run_review_test.rb` adds focused coverage for
triage limit vs non-limit marker behavior, while existing reviewer/healer tests
cover all-reviewers limit classification and cooldown clearing.

Updated [[stages/review]], [[modules/daemon]], and [[state-model]] so review
`limits_reached` documentation includes reviewers, triage, and fix phase
markers. Updated [[testing]] for the `run_review_test.rb` and
`run_reviewers_test.rb` coverage. Updated [[active-areas]] with the latest
review-limit healing commit. Updated [[gaps]] to record the remaining
uncertainty: no focused assertion was found for the fix-phase
`limits_reached` helper path, and no checked-in live artifact proves a fresh
headless/tmux/review run surfacing and daemon-healing the marker through
`hive status`, TUI, or daemon logs. Page coverage did not change, so
[[index]] was not edited. Did not edit compiled [[log]], and did not run
`qmd update` or `qmd embed`.

---
date: 2026-06-28
slug: review-limit-text-threading
pages: [state-model, stages/review, testing, gaps]
---

Review-stage provider-limit handling now threads structured `limit_text` from
Claude/tmux waits through triage, CI-fix, and fix sinks instead of re-parsing
lossy AgentLimit-formatted messages. `Hive::AgentLimit.live_limit_line` owns the
tight live-pane detector for real Claude limit menus, while `from_limit?`
recognizes only AgentLimit's own wire format for legacy strings. Review
`limits_reached` cooldown markers can now come from reviewers, triage, CI-fix,
or fix, and quoted limit text in a healthy pane remains non-fatal.

Updated [[state-model]], [[stages/review]], and [[testing]] to document the new
CI-fix limit path, raw `limit_text` producers, checked-in pane fixtures, and the
load-bearing healer cooldown assertion. Updated [[gaps]] to close the stale
private-test/fix-phase coverage note while preserving the remaining live-smoke
gap. For pre-fix `REVIEW_ERROR` rows that were actually usage limits but were
written as `triage_failed`, `fix_failed`, or `ci_unrunnable`, the operator
recovery is `hive markers clear <slug> --name REVIEW_ERROR --project <project>`
to re-dispatch.

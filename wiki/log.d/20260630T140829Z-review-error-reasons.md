---
date: 2026-06-30
slug: review-error-reasons
pages: [active-areas, stages/review, state-model, modules/markers, commands/tui, testing]
---

Added `Hive::ReviewErrorReason` for residual 6-review triage/fix phase-agent
failures. `mark_review_phase_failure` still checks `Hive::AgentLimit` first, so
provider quota/rate/429 text continues to write `reason=limits_reached` with
`retry_after` for daemon cooldown healing. Non-limit triage/fix errors now write
a closed terminal reason (`merge_conflict`, `network_timeout`,
`tool_permission_denied`, `agent_crashed`, or `unknown`) while preserving the
existing capped `message=` cause.

Tests now cover the standalone classifier, triage and fix integration through
the runner, the generic `unknown` fallback, and the TUI status column rendering a
classified `reason=` value verbatim. Refreshed current wiki pages to describe the
new marker vocabulary and kept historical `wiki/log.d/` fragments unchanged.

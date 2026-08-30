## [2026-08-30] Preserve successful reviewer evidence across failed retries

**Action:** Agent-backed and native Codex reviewers now write to a per-pass
staging path and atomically publish the canonical findings file only after a
successful run. Failure cleanup targets the staging path, so a crashed or
quota-rejected retry cannot erase an earlier successful result from the same
review pass.

**Pages updated:** wiki/modules/reviewers.md,
wiki/log.d/20260830T210937Z-reviewer-output-staging.md

**Source:** `lib/hive/reviewers/base.rb`, `lib/hive/reviewers/agent.rb`,
`lib/hive/agent_support/codex/reviewer.rb`, `lib/hive/stages/review.rb`, and
reviewer/orchestrator regression tests

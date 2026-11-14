---
title: Provider quota walls retry hourly and never park; idle usage sessions are hidden
type: fix
created: 2026-11-14
updated: 2026-11-14
tags: [review, plan-review, recovery, provider-limit, usage, web]
---

Operator decision: a provider quota/usage-limit failure is not a
deterministic failure. It never counts toward the identical-failure park and
retries on the fixed `AgentLimit.retry_cooldown_sec` cadence (3600s by
default; `HIVE_LIMITS_RETRY_COOLDOWN_SEC` overrides), never on the
provider-announced reset time.

- 6-review: a pass where some reviewers succeeded and **every** failed
  reviewer hit a provider limit now writes `REVIEW_ERROR phase=reviewers
  reason=limits_reached` instead of `reviewer_partial_failure`.
  `RecoveryCoordinator` already exempts `limits_reached` from
  `deterministic_failure` and delays it by the hourly cooldown. Field case:
  todero `typed-lists-foundation-to-do-261105-4e88` recorded 66
  `reviewer_partial_failure` exits from a Muse `API error 429 …
  Subscription quota exhausted` beside a healthy Codex reviewer, then parked.
  A mix that includes a non-limit reviewer failure is unchanged.
- Plan review: a `provider_limit` adapter outcome gets `retry_at = clock +
  retry_cooldown_sec` (the Codex "try again at" time is ignored) and no longer
  counts in `attempts_in_current_run`, so it never exhausts
  `max_transient` or blocks verification as
  `candidate_verification_provider_limit`.
- Muse's run-terminal 429 text classifies as `:provider_limit` (component
  test pins the field message).
- Task workspace usage: `usage.groups` omits finished sessions with no usage
  row or all-zero token categories; totals and counts are unchanged. The Web
  usage card shows one "N technical retries with no metered usage hidden"
  line.
- Pages: [[stages/review]], [[modules/plan_review]], [[token-usage]].

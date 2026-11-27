# 2026-11-27 — Babysitter suppresses PR comments on quota, capacity, and transient operational errors

- Added `Hive::Babysitter::FailureClassifier` (`lib/hive/babysitter/failure_classifier.rb`)
  so `PrFixer` classifies all non-PR provider and operational failures before
  `:timeout` and `:failure` give-up handling:
  - Quota, rate-limit, usage-cap, billing/credit exhaustion, HTTP 402/429, and
    quota-caused timeouts (`timed_out: true` + `limits_reached` / limit text)
    resolve to `:limits_reached` with the hourly `AgentLimit.retry_due?` hold
    in `.hive-state/babysitter/agent-limit-hold.json` and zero GitHub PR
    comments or `babysitter/needs-human` labels.
  - Provider capacity/overloaded/5xx/network errors (`error_reason: "provider_error"`,
    structured `provider_error`/`provider_signal` envelopes, unambiguous
    529/503/502/504/capacity/stream-disconnect lines) and local-host
    operational errors (`preflight_failed`, `authentication_failure`,
    `provider_route_failed`, `provider_route_preflight_failed`,
    `process_cleanup_failed`) resolve to `:provider_error` with a 5-minute
    `hold_until` backoff in `agent-limit-hold.json`, structured local
    `agent-fix` / `skipped` events (with `provider`, `reason`, and redacted
    `message`), and zero GitHub PR comments or labels.
- Added `"provider_error"` to `Hive::Babysitter::Events::OUTCOMES` and
  `provider_error: :retry` to `Hive::Babysitter::ProjectTick::OUTCOME_CLASSES`
  (not counted as `needs_human`, projected as `waiting_external` in one-shot).
- Preserved give-up comments and labels for genuine PR repair failures,
  wall-clock repair timeouts without provider errors, per-run budget
  exhaustion (including `failure_origin: "budget_exhausted"`), and ADR-057
  `model_unsupported`.
- See [[modules/babysitter]] and [[commands/babysit]].

---
slug: improve-hive-web-task-detail-260812-19e1
created_at: 2026-08-12T15:48:18Z
original_text: |
  Improve Hive Web task detail into a clearer feature workspace without replacing Hive's existing task page. Add task-scoped repository-context provenance that records repository HEAD, LLM Wiki revision/freshness, selected wiki pages or query results, inclusion rationale, and the context snapshot used by brainstorm/plan/execute. Add an active-agent session panel showing provider, actual model, reasoning effort, stage/phase, start time, timeout/budget guard, attempt identity, health, and live/completed state. Add a unified chronological decision timeline across questions, answers, approvals, retries, recovery events, stage transitions, and material plan-review findings. Add dependency and stacked-flow visualization for atomic task chains, including blocked-by relationships, base/head ordering, current task, and PR links. Add an integrated publish/PR preview beside the bounded diff with branch/base/head identity, commit summary, PR title/body preview, checks, and publication state. Reuse existing pushed task-state contracts and artifacts rather than creating a separate feature database or lifecycle; preserve filesystem-backed durability, authorization boundaries, bounded reads, and recovery semantics. Define responsive and accessible UI behavior, stable JSON/API additions with versioning and compatibility, empty/degraded/error states, tests, documentation, and browser coverage.
---

# improve-hive-web-task-detail-260812-19e1

Improve Hive Web task detail into a clearer feature workspace without replacing Hive's existing task page. Add task-scoped repository-context provenance that records repository HEAD, LLM Wiki revision/freshness, selected wiki pages or query results, inclusion rationale, and the context snapshot used by brainstorm/plan/execute. Add an active-agent session panel showing provider, actual model, reasoning effort, stage/phase, start time, timeout/budget guard, attempt identity, health, and live/completed state. Add a unified chronological decision timeline across questions, answers, approvals, retries, recovery events, stage transitions, and material plan-review findings. Add dependency and stacked-flow visualization for atomic task chains, including blocked-by relationships, base/head ordering, current task, and PR links. Add an integrated publish/PR preview beside the bounded diff with branch/base/head identity, commit summary, PR title/body preview, checks, and publication state. Reuse existing pushed task-state contracts and artifacts rather than creating a separate feature database or lifecycle; preserve filesystem-backed durability, authorization boundaries, bounded reads, and recovery semantics. Define responsive and accessible UI behavior, stable JSON/API additions with versioning and compatibility, empty/degraded/error states, tests, documentation, and browser coverage.

## Operator addition during brainstorm: budget visibility

Make budget a first-class part of the task workspace, not only a timeout label.
Show the configured per-stage/per-spawn budget guard, its configuration source
and scope, observed usage when the provider reports it, and remaining headroom
when that value can be computed honestly. Distinguish monetary/API budgets from
subscription capacity, token/launch quotas, and timeouts; a `budget_usd` guard
on a subscription-backed provider must not be presented as an extra charge.
Represent unavailable, estimated, stale, exhausted, and retry-after states
explicitly. Attribute usage to provider/model/attempt/stage, preserve historical
attempts without double-counting the current total, and keep all displays based
on bounded, versioned task-state/usage contracts with authorization-safe detail.

<!-- WAITING -->

---
title: Answered max-pass REVIEW_STALE escalations unlock workflow.retry
type: change
created: 2026-11-10
updated: 2026-11-10
tags: [review, recovery, operational-status, cli, daemon]
---

A max-pass `REVIEW_STALE` (including `reason=final_fix_unverified`) used to
stay operator-owned forever on the CLI and agent path: answering
`reviews/escalations-NN.md` made that file newer than any `fix-success-NN.md`,
so `Hive::Recovery.review_stale_recovery_state` kept returning `:operator`,
operational status had `action: null`, and only the TUI's forced `r` could
resume the task.

`review_stale_recovery_state` now returns `:operator_answered` when the
marker pass's escalations file has at least one non-empty `### A<n>.` answer
(when the marker records `escalations=M`, the answers must leave fewer than M
questions open, so answers present at stall time do not count). The Q/A parser
moved from `Hive::Stages::Review` into `Hive::ReviewEscalations` so the review
runner and the recovery predicate share it.

- `intervention_required?` stays `== :operator`, so `OperationalAction` offers
  the guarded `workflow.retry` for the answered shape and `hive act` submits it
  through `RecoveryCoordinator` (requestor `action`), the same admission the
  TUI's forced `r` uses. Bot Autofix becomes available for the same rows, and
  the diagnostic suggests the guarded retry command instead of `manual_fix`.
- New `operator_owned_review_stale?` (`:operator` or `:operator_answered`)
  gates `StaleAgentHealer`, so the daemon never retries either shape.
  `TaskAction.max_passes_review_stale_with_escalations?` uses it as well,
  keeping the TUI's Enter-browse / `r`-retry gesture unchanged.
- Operational status reports `recovery.status=blocked owner=operator
  reason=operator_retry_required` for the answered shape instead of
  `recovery_observation_missing`.
- `hive run`/`hive review` next-action text and the stage pre-flight warning
  share `Hive::Recovery.review_stale_guidance`, which names the escalations
  file, says to answer and then invoke `workflow.retry`, and points
  `final_fix_unverified` rows at the review grant (before answering) when Hive
  should apply fixes.

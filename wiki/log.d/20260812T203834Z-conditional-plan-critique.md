---
title: Add conditional plan critique authority
date: 2026-08-12T20:38:34Z
tags: [plan-review, policy, findings, coverage, daemon, status, web]
---

Built-in coding plans now pass through a policy-driven critique substate inside
`3-plan`. Deterministic signals choose `skip`, `standard`, or `mandatory`;
non-skipped plans use immutable snapshots, CE whole-document review, an
independently attested adversarial route, typed findings, one original-planner
revision, and one verification pass. Immutable task-local history and an atomic
current resolution retain route, coverage, decision, and degradation evidence.

The current freshness-bound resolution is now the sole `3-plan` to `4-execute`
authority across workflow verbs, generic/forced approval, direct execute entry,
daemon recovery, TUI/status, and Hive Web. New and migrated pre-execute coding
tasks carry a durable metadata requirement so deleting review artifacts cannot
masquerade as a pre-feature execute task; genuinely existing execute tasks keep
an explicit adoption receipt.

Operators can apply exact idempotent approvals, answers, waivers, raises,
downgrades, and retries through `hive plan-review` or the shared Web service.
Status schemas expose one required nullable projection across CLI,
operational status, daemon, TUI, and Web. Offline lifecycle proof covers every
terminal outcome; an opt-in authenticated smoke requests native Grok Build
`grok-4.6` and verifies the different-family receipt without retaining
credentials.

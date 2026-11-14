---
title: Doctor warns when the plan-review adversary shares the planner's model family
type: change
created: 2026-11-14
updated: 2026-11-14
tags: [doctor, plan-review, config, model-routing]
---

On 2026-11-14 the planner in `todero` and `openclaw-shopping` moved from Muse
to Codex (`gpt-6.1-sol`). Their `plan_review.routes.adversarial` stayed on
Codex (`gpt-6-astra`, family `openai`), so every new plan review failed
adversarial coverage with `same_model_family`
(`PlanReview::RouteResolver#independence`). The tasks then sat in
`needs_repair` with "waive named coverage or restore required reviewer
capability". The misconfiguration was visible only after each plan had been
written and reviewed.

- `hive doctor` adds `check_plan_review_independence`. When the adversarial
  route's `family` (or the family of its `agent`) equals the plan stage
  agent's family (`PlannerIdentity.family`), it emits a
  `plan_review/independence` warning naming the family and the planner.
  Warning rows never change the exit code. Unknown families and the default
  routes (grok adversary, claude planner) stay silent.
- Operator fix applied on the dogfood host: the adversary in both projects
  now routes to `claude` / `claude-opus-5-5` / `anthropic`, matching `hive`
  and `hivedev`.

Tests: `test/unit/commands/doctor_test.rb` covers the same-family warning (no
exit-code or failure-count change), the independent adversary, and the
default routes. A check against todero's real pre-fix config warned, and its
fixed config did not.

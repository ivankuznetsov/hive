## 2026-11-22 — Decision triage gets its own configurable route

- Decision triage was hard-wired to the verification route
  (`Orchestrator#dispatch_attempt`), so its model and effort could only be
  changed by changing verification too. On uk-new-companies it also showed the
  verification row's inherited Codex labels (`family: openai`,
  `route: native_codex`) while running Claude Opus.
- Projects may now set an optional `plan_review.routes.decision_triage` row with
  the same keys as the other review routes. When it is absent, triage still
  uses the verification route. The capability probe uses the same mapping.
- The row is validated like `planner_revision_fallback`. It is part of
  reviewer routing (the policy fingerprint), so changing it rekeys an
  unresolved review but not a resolved one. Its model-routing identity stays
  `plan_review_verification`.
- Pages: [[modules/plan_review]].

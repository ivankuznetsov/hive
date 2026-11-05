# 2026-11-05 — Muse planner model family

**Action:** `Hive::PlanReview::PlannerIdentity::FAMILIES` maps `muse` to
`meta`. Before this, a Muse planner reported family `unknown`, so
`RouteResolver.independence` returned `planner_family_unknown` for every
reviewer and the required adversarial coverage failed closed; any project
planning with Muse could not pass plan review. A Codex (`openai`) adversary
now verifies as independent; a Muse reviewer of a Muse plan stays
`same_model_family`.

**Verification:** `test/unit/plan_review/` passes locally.

**Wiki:** No page change; see [[gaps]] for remaining Muse boundaries.

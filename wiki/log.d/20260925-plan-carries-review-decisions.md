# 2026-09-25 — New linked plans carry the blocked review's operator decisions

- When a plan review ends `blocked` (for example at its revision-round limit)
  and asks for a new linked plan, `Stages::Plan` now passes every operator
  approval and answer from that review to the planner as a
  `plan_review_decisions` user-supplied data block. Those decisions could exist
  only in candidate plans that were never promoted to `plan.md`, and the
  planner prompt carried only `brainstorm.md` and `plan.md`, so the next review
  re-raised questions the operator had already answered (observed: a receipt
  storage choice asked again after it was answered and verified).

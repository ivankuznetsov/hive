# 2026-09-26 — Late operator decisions get one integration round

- A plan review that spent its three planner-revision rounds on `safe_auto`
  fixes blocked (`revision_round_limit`) as soon as the operator approved a
  gated finding or answered a manual one, so every late decision demanded a new
  linked plan. The new plan's fresh review surfaced another batch and the cycle
  repeated: one task went through seven linked plans.
- `Orchestrator#revision_round_limit_reached?` now allows one extra round
  (`OPERATOR_DECISION_ROUNDS = 1`) when the accepted findings include an
  operator decision. Safe-only residue still blocks at three rounds, and the
  ceiling is fixed at four, so the loop stays bounded.

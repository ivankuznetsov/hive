# 2026-09-28 — Accepted wrong-kind evidence becomes a recorded revise

- `OutcomeEvidence::Contract.review!` raised `StoreError` when a reviewer marked
  a claim `accepted` whose evidence used the wrong proof kind (for example a
  terminal cast for a `document` claim). The whole round was discarded, so no
  revision guidance reached the next producer, and one task's producer repeated
  the identical mismatch ("claim schema-rollout requires document proof, not
  terminal") on consecutive rounds.
- Such a verdict is now downgraded to `revise`, with a controller reason naming
  the required and supplied kinds. The round is recorded and the next producer
  recaptures the right kind. Wrong-kind proof still can never be accepted, and
  `rework`/`blocked` verdicts are kept as given.

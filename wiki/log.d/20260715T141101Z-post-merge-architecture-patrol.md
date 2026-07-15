# 2026-07-15 — Add scheduled post-merge architecture patrol

**Action:** The existing daemon patrol cadence now opens and drains durable
post-merge architecture batches when both ordinary patrol and refactor-patrol
are enabled. Local first-parent history attributes one reporting-only child per
PR, each pinned to the registered healthy trunk and its merge's first-parent
boundary. Checkout, capability, and bounded-scope failures remain retryable and
independent from ordinary patrol outcomes.

**State and reports:** New state under
`.hive-state/refactor_patrol/post_merge/` records a non-retroactive baseline,
active batch, contiguous checkpoint, per-merge attempts, and emission digests.
Schema-valid per-PR reports preserve accepted/flagged/suppressed totals,
actionable flagged-thesis details, and idempotent new/changed emission deltas.
Report and ledger persistence precede processed/checkpoint state so restart can
reconcile interrupted completion safely.

**CLI and tests:** `hive refactor-patrol --path` now accepts repeated bounded
paths while preserving feature/entrypoint precedence. Hermetic unit and
integration coverage pins local capability probing, trunk guards, merge
cataloguing, scope selection, scheduler/dispatcher isolation, crash recovery,
report schema, and two-PR cadence-to-checkpoint completion without GitHub or
provider calls.

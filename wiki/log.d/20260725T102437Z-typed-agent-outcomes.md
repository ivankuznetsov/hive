## Typed agent outcomes and Brainstorm artifact truth

- **Action**: Classified Claude's structured per-run budget stop separately
  from account/rate/quota limits, centralized the built-in Content workflow
  budgets, and reconciled Brainstorm spawn/receipt outcomes with its required
  artifact.
- **Behavior**: `error_max_budget_usd` now yields typed
  `budget_exhausted` details and an operator-facing stage-budget remedy.
  Coding Brainstorm accepts only a numbered Round for WAITING or non-empty
  Requirements for COMPLETE, ignores same-named generic workflow stages,
  rejects unchanged stale output after a failed spawn, and admits one repair
  per distinct request when a successful terminal receipt has no valid
  artifact.
- **Verification**: Focused Agent, Content workflow, Brainstorm runtime,
  durable dispatcher, neighboring stage, and integration tests cover the new
  outcomes and existing launch paths.

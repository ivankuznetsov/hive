# Repair benchmark controller composition

Review reproduced failures from the unsealed origin variable and ManagedGit environment scrubbing, plus shallow-history push rejection. The controller now retains a fixed sealed origin after environment scrubbing, initializes an origin for both modes, accepts shallow history, and registers an existing unsealed remote idempotently. Privileged initialization ignores candidate global config and templates; repository Git runs after privilege drop and refuses URL rewriting on pushes.

Focused regressions and a real network-disabled root-container setup canary cover these boundaries. The Pi extension was executed against both supported routes and unrelated/missing models. A complete model-driven review cycle remains unproven.

## Consolidate condition-transition membership into Policy

- Removed `default_transitions` from `Hive::Conditions::Registry` and
  `Definition`. It was a second, unused owner of condition-to-transition
  membership and had already drifted (`AgentHealthy` pointed at the
  non-existent `execute_active` gate instead of `execute_to_open_pr`).
- `Conditions::Policy.default` is now the single internal representation of
  transition membership; the registry keeps only condition semantics
  (family, scope, evidence, gate role, authoritative stages).
- Regression coverage: registry definitions no longer expose
  `default_transitions`, and every condition named by a policy rule must be
  registered vocabulary.

## Patrol Fix live qualification now exercises authenticated strict gates

- The opt-in Patrol Fix corpus preserves the operator's authenticated agent
  home only when both required absolute paths are supplied; ordinary tests
  remain isolated from user agent and GitHub state.
- Semantic admission now rejects wrong-shaped rationale, evidence, and
  candidate bindings at the provider edge instead of relying on the later
  admission-store validation.
- Feature-classification prompts no longer ask the model for the
  controller-generated `model_receipt`, matching the strict runner parser.

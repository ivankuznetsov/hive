## 2026-08-27 — Grok Build served-model identity

Grok Build accepts the public `grok-4.6` request but reports
`grok-4.6-build` in its terminal usage event. Hive now recognizes that exact
served-name transition as the same Grok model, so the route retains its `grok`
family and can satisfy independent coverage without an operator waiver.
The exact mapping lives in Grok's agent-support module; the shared plan-review
adapter remains provider-neutral and still drops family on unknown overrides.

The opt-in authenticated smoke test pins the requested name, the two accepted
terminal identities, and independence. A focused adapter test rejects unrelated
served-model overrides as before.

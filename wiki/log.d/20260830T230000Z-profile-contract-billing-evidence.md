# 2026-08-30T23:00:00Z — Billing evidence reads the profile contract only

- **Task**: make-one-profile-level-billing-evidence-contract-f7a0c3957f70 (patrol fix, generation 1)
- **Thesis**: `pr-1347-f4b12c802fffce76:make-profile-billing-evidence-authoritative`

## What changed

`Hive::BillingEvidence.for_profile` admitted profiles by adapter name
(`DIRECT_SUBSCRIPTION_ADAPTERS = %w[claude codex grok]`) in addition to the
profile's declared `billing_semantics`. The Pi profile declares
`subscription_backed` (it requires a CLI subscription/session artifact, per
[[modules/agent_profile]]), yet was omitted from the name allowlist, so two
policy owners disagreed: the profile contract said subscription-backed while
billing evidence recorded `unknown/unavailable`.

The adapter-name allowlist is removed. A profile that declares
`subscription_backed` proves subscription semantics from its own contract
(`subscription` / `agent_profile_contract`); every other declaration stays
`unknown`/`unavailable` unless an admitted provider-account configuration
declares the route. The now-unused `DIRECT_SUBSCRIPTION_ADAPTERS` constant and
its `ProviderRouting` re-export were removed.

## Behavioral impact

- Pi launches without an explicit provider-account `billing_route` now record
  `subscription` / `agent_profile_contract` instead of `unknown`/`unavailable`.
- OpenCode and any profile not declaring `subscription_backed` are unchanged.
- Regression coverage: `test/unit/billing_evidence_test.rb` (contract is the
  single authority across the registered profile set, plus name-independence
  and fail-closed cases); `ProviderRoutingConfigurationTest` pi expectations
  updated accordingly.

## Follow-ups

- `wiki/token-usage.md` updated to describe the contract-authoritative rule.

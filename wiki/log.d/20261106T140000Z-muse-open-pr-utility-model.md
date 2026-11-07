# 2026-11-06 — Muse tasks can open their PR

**Action:** `Hive::ImplementationIdentity::UtilityModels::REGISTRY` had no
`muse` entry, so every Muse-executed task failed at `5-open-pr` with
`ResolutionError: no open-PR utility model policy for provider :muse`
(dogfood, openclaw-shopping foundation, 2026-11-06). Added
`muse: { model: nil, pin_model: false }` and a `Muse.downstream_model` hook
that keeps open-PR on the exact execute model when the provider is unchanged
(mirroring OpenCode), so open-PR does not depend on a `model` key in the
operator's Muse `settings.json`. A new guard test asserts every built-in
provider in `AgentCliRuntime::Profiles::PROVIDER_ORDER` has an open-PR
utility policy.

**Verification:** agent-profiles, implementation-identity resolver, and Muse
agent tests pass.

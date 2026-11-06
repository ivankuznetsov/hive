# 2026-11-05 — Codex can attest its OpenAI family as a plan-review adversary

**Action:** Plan review requires the adversarial reviewer's model family to be
attested and to differ from the planner's. Families were attested only from a
served-model field matching the requested model, but Codex's `exec --json`
stream (`thread.started`, `turn.started`, `item.completed`, `turn.completed`)
never names the model. A Codex adversary therefore always came back
`reviewer_family_unknown`, the required adversarial coverage failed, and every
plan review blocked (seen with a Muse planner and a Codex `gpt-6-astra`
adversary in openclaw-shopping).

`RouteResolver.attest_observed_identity` now asks the provider's support module
`attests_family_without_served_model?(family:)` when no served model was
observed. `Hive::AgentSupport::Codex` answers true only for family `openai`
and only when the operator's replayed Codex config selects no non-OpenAI
`model_provider`, at top level or through the active `profile` (Hive launches
Codex with `--ignore-user-config` and replays only those keys). An unreadable
or malformed provider value fails closed. Other providers keep the old
served-model-only rule.

**Verification:** plan-review unit tests pass, including new resolver cases for
each config shape and an adapter-level regression; the helper-subagent usage
model is still never taken as reviewer identity.

## 2026-11-20 — Opt-in provider-limit fallback for implementation stages

- Symptom: Codex was out of quota until 2026-11-23 14:18 UTC and Muse until
  2026-11-23 00:00 UTC. The operator rerouted project config to grok, but
  hivedev `adr-0004-rollout-step-3-261115-9cdb` kept failing `limits_reached`
  on its Codex open-PR author, and two todero tasks stayed pinned to Muse at
  4-execute. Execute and open_pr resolve their implementation identity once
  per generation and persist it to the task journal, so a config change never
  reaches a task whose identity is already resolved.
- Change: new opt-in `implementation.limit_fallback`
  (`{ enabled: false, min_wait_sec: 3600, agents: {} }`), a sibling of
  `review.limit_fallback` with the same shape and validator
  (`Config.validate_limit_fallback!`). The decision rules moved into the
  shared `Hive::LimitFallback` core; `Review::LimitFallback` binds it to its
  own path, and the new `Hive::ImplementationLimitFallback` binds it to the
  implementation stages. It covers the execute implementer, the open-PR
  author, the artifacts inference and reviewer roles, and the finalize
  agent. It fires only for a launch the stage classified as `limits_reached`,
  with an explicit reset absent or at least `min_wait_sec` away, and never
  under explicit provider-account routing.
- Identity: `Resolver#resolve_limit_fallback` uses the stage config's own
  model when that config names the fallback agent, else the fallback
  profile's default. The substitution is journaled as the new
  `implementation_identity_substituted` event (primary kept for audit,
  substitute that actually ran, `scope: "attempt"`) before the substitute
  launches. The pin is never rewritten: the next attempt re-evaluates the
  primary's limit.
- Status: `implementation_identity.substitutions`, `held.fallback`
  (`available` from config, else the marker's `fallback_outcome=`), the
  `limit_fallback_used` operational reason, and `provider.fallback`. Failed,
  limited, deferred, unresolved, or unsupported fallbacks annotate the
  primary's `limits_reached` marker with `primary_agent` / `fallback_agent` /
  `fallback_outcome`.
- Pages: [[modules/config]], [[stages/execute]], [[stages/open-pr]],
  [[stages/artifacts]], [[stages/finalize]], [[stages/review]],
  [[state-model]], [[commands/status]], [[gaps]].

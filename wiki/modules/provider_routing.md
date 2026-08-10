---
title: Hive::ProviderRouting policy
type: module
source: lib/hive/provider_routing.rb, lib/hive/provider_routing/*.rb
created: 2026-08-10
updated: 2026-08-10
tags: [config, provider-accounts, routing, policy, validation]
---

**TLDR**: `Hive::ProviderRouting` is the immutable, pure opt-in policy boundary
for provider-account routing. A stage without `routing.pool` receives a
structural legacy policy before Hive reads global provider accounts, health, or
capacity. An explicit pool freezes ordered account, adapter, non-secret launch
binding, model, effort, compatibility metadata, hard requirements, strict pin,
and a canonical digest. Health, admission, capacity, attempts, retry, and
recovery are not owned here.

## Global provider accounts

Provider accounts live in global Hive config because their external adapter
contexts and concurrency are shared across projects:

```yaml
providers:
  codex-primary:
    adapter: codex
    launch_binding: default
    models: [gpt-5.6-sol, gpt-5.6-terra]
    max_concurrent: 2
    cooldown_sec:
      account_quota: 3600
      provider_rate_limit: 300
```

`launch_binding` is a bounded symbolic identity resolved by the adapter layer;
it is never a token, credential path, or environment value. Account IDs are
normalized. Models are an explicit allowlist. Two accounts using one adapter
must have distinct launch bindings, and only one can therefore use `default`.
Cooldown values are bounded and keyed by the closed account-health taxonomy.

The registry is dormant unless a project declares an explicit pool. A malformed
global `providers:` value cannot break a project that has no pool.

## Per-stage policy

```yaml
execute:
  routing:
    pool:
      - provider: codex-primary
        model: gpt-5.6-sol
        effort: xhigh
        capabilities:
          context: large
          quality: high
          tools: [shell, filesystem]
          permissions: [read, write]
    required:
      quality: high
      tools: [filesystem]
    pin:
      provider: codex-primary
      model: gpt-5.6-sol
```

Pool entries cannot choose or override an adapter. The account derives exactly
one registered `AgentProfile`. Each candidate resolves model and effort through
the existing exact/coarse/current `Hive::ModelRouting` precedence, then validates
the resolved model against the account allowlist and the controls against the
profile. Account identity remains separate from implementation identity's
`provider`, which continues to mean adapter/profile.

Requirements are hard filters over only the frozen route metadata. Provider
pins retain only that account's configured routes; provider-plus-model pins are
exact. Unknown accounts/models, duplicate normalized routes, duplicate launch
bindings, adapter overrides, unsupported metadata, impossible requirements,
and unmatched pins fail during configuration loading before dispatch.

Configured order is authoritative. Static compatibility filtering never
reorders survivors; normalized route ID is only a defensive tie-breaker when
values are constructed with the same order. The SHA-256 policy digest covers
all selection-affecting normalized policy and account fields, including the
non-secret launch-binding identity, but contains no credential material.

## Immutable values and ownership

`Account`, `Route`, `Requirements`, `Pin`, `Policy`, `Request`, `Decision`, and
`Configuration` own deeply frozen data. `Policy.legacy` has no routes or digest.
An explicit `Policy` exposes the complete normalized pool and its statically
eligible ordered routes. Later admission/health work consumes these values; it
must not add retries, deadlines, queues, leases, provider-specific fallback, or
another recovery owner.

Shared circuit state is a separate `Hive::ProviderHealth` component described
in [[modules/provider_health]]. Its account and exact-model journals are
consulted only for an explicit pool; the structural legacy policy never opens
that store. Health cooldown controls half-open route eligibility only and does
not schedule a retry.

Sanitized adapter-channel inventory lives under
`test/fixtures/provider_errors/`. No retained real capture currently proves a
stable explicit account/model scope for Claude, Codex, Pi, or Grok, so all
listed provider/model classes remain task-local pending reviewed evidence.

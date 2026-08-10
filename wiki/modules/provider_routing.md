---
title: Hive::ProviderRouting policy
type: module
source: lib/hive/provider_routing.rb, lib/hive/provider_routing/*.rb
created: 2026-08-10
updated: 2026-08-10
tags: [config, provider-accounts, routing, policy, validation]
---

**TLDR**: `Hive::ProviderRouting` is the immutable, pure opt-in policy and decision boundary
for provider-account routing. A stage without `routing.pool` receives a
structural legacy policy before Hive reads global provider accounts, health, or
capacity. An explicit pool freezes ordered account, adapter, non-secret launch
binding, model, effort, compatibility metadata, hard requirements, strict pin,
and a canonical digest. Health, admission, capacity, attempts, retry, and
recovery are not owned here. `Router` consumes immutable health and durable
capacity observations and returns an explainable decision without reserving a
route.

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

`Router` evaluates every configured candidate in stable order. It applies the
hard pin and requirements first, then enclosing provider/model health, then the
provider-account concurrency observation. A saturated preferred account is
skipped for a later eligible route. If every statically compatible route is
saturated, the decision is scheduler-owned `capacity_saturated`; health or
policy exhaustion is `no_eligible_provider_route`, while unavailable health
fails closed with an operator owner. Decisions retain ordered candidates,
typed exclusions, observed/max capacity, both circuit generations, optional
probe requirements, and a caller-supplied observation identity/time.

Before the first explicit selection for a durable subject generation,
`ProviderRouting::PolicyStore` records the complete normalized policy under
`$HIVE_HOME/attempts/v4/routing-policies/v1/`. The cell is point-addressed by
the opaque ownership generation and strict attempt subject, owner-private, and
first-writer-wins. Reads reconstruct the policy and recompute its canonical
digest; schema-valid tampering therefore still fails closed. Only symbolic
launch-binding identity is stored. Legacy policies return before key validation,
schema loading, directory creation, or any policy-store I/O.

The selected route remains separate and attempt-scoped. Attempt schema v4
stores the adapter/profile in its existing `provider` field and stores account,
launch binding, model, effort, decision, circuit generation vector, and probe
bindings inside the immutable explicit-routing arm. `Attempts::Context` exposes
that persisted route to the authenticated worker; mutable project configuration
cannot replace it after admission.

Shared circuit state is a separate `Hive::ProviderHealth` component described
in [[modules/provider_health]]. Its account and exact-model journals are
consulted only for an explicit pool; the structural legacy policy never opens
that store. Health cooldown controls half-open route eligibility only and does
not schedule a retry.

The Attempts dispatcher freezes the policy and invokes this pure router while
holding its existing admission and task-generation locks. It then asks health
to revalidate the selected route's complete generation vector. Any concurrent
health mutation causes a bounded re-selection; only a still-current decision
may be persisted with a launching attempt.

Sanitized adapter-channel inventory lives under
`test/fixtures/provider_errors/`. The allowlisted files are explicitly marked
as sanitized adapter-contract fixtures, not upstream captures. Only those
exact structured envelopes with matching configured account/model identity
can become shared evidence; prose and other shapes remain task-local. The
adjacent `real_capture_pending` files preserve the operational proof gap rather
than overstating fixture provenance.

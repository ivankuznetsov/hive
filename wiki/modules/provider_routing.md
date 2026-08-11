---
title: Hive::ProviderRouting policy
type: module
source: lib/hive/provider_routing.rb, lib/hive/provider_routing/*.rb
created: 2026-08-10
updated: 2026-08-11
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
route. The public `require "hive/provider_routing"` entrypoint resolves both
the immutable values and `ProviderRouting::PolicyStore` without relying on an
Attempts require to have run first.

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
must resolve to distinct launch-binding identities, including after named
credential-directory paths and an existing default session directory are
canonicalized, and only one can therefore use `default`. An explicit policy validates every named binding as an existing
absolute directory before it can enter a route. Missing or inaccessible named
bindings are configuration errors rather than eligible candidates that fail
after commitment.
Named bindings additionally remove the selected agent-compatibility profile's
recognized ambient credential variables for the child process. For Pi this
ensures route identity comes from the selected subscription/session directory
rather than an inherited API key or token. The variable inventory belongs to
`agent-cli-runtime` and is parity-tested against Hive's temporary internal
profile copy.
Cooldown values are bounded and keyed by the closed account-health taxonomy.

The registry is dormant unless a project declares an explicit pool. A malformed
global `providers:` value cannot break a project that has no pool.

## Per-stage policy

Provider routing is configured at a durable stage boundary. In particular,
`review.routing` selects the route for the complete review attempt and
`patrol.routing` selects the route for the complete Patrol attempt. Nested
`review.{ci,triage,fix,browser_test}.routing`, per-reviewer routing, and Patrol
per-reviewer routing are rejected because those actors do not own independent
durable attempts. Their existing model/effort and permission controls remain
available.

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
skipped for a later eligible route. If every statically compatible unpinned
route is saturated, the decision is scheduler-owned `capacity_saturated`. A
strict pin excluded by saturation is instead `no_eligible_provider_route` with
the exact `provider_concurrency_saturated` exclusion, like every other
strict-pin exclusion. Health or policy exhaustion is also
`no_eligible_provider_route`, while unavailable health fails closed with an
operator owner. Store construction and preselection reconciliation failures
use that same typed path, so even an unavailable health root leaves a durable
decision instead of escaping admission as an exception. Decisions retain ordered candidates,
typed exclusions, observed/max capacity, both circuit generations, optional
probe requirements, and a caller-supplied observation identity/time.
One candidate can carry all four enclosing health blockers (provider and model
scopes, each with `circuit_open` plus `circuit_cooldown`), while the complete
1,024-candidate decision remains bounded to 4,096 exclusions.

An automatically open circuit that is still waiting for its eligibility time
emits both `circuit_open` (the durable health state) and `circuit_cooldown` (the
current time gate), in that order. Once the time arrives, the scope is
half-open and ordinary admission may claim its probe instead of emitting either
exclusion.

Before the first explicit selection for a durable subject generation,
`ProviderRouting::PolicyStore` records the complete normalized policy under
`$HIVE_HOME/attempts/v4/routing-policies/v1/`. The cell is point-addressed by
the opaque ownership generation and strict attempt subject, owner-private, and
first-writer-wins. Reads reconstruct the policy and recompute its canonical
digest; schema-valid tampering therefore still fails closed. Only symbolic
launch-binding identity is stored. Legacy policies return before key validation,
schema loading, directory creation, or any policy-store I/O.

The routing-policy component owns those first-writer-wins snapshot mutations;
it uses the lower-level `Hive::PointStorage` custody primitive rather than an
Attempts-internal store. Attempts owns admission and supplies the root and lock
ordering, but it is not a hidden dependency of policy normalization or
persistence.

Release incident coverage uses that same production admission boundary. The
AE2-AE8 matrix admits routed work through `Attempts::Dispatcher`, derives
provider capacity from live v4 attempt records, binds health observations to
immutable terminal receipts, and reopens both Attempts and Provider Health
stores at restart points. At least one accepted route is claimed, run, and
terminalized by `Attempts::Supervisor`; impossible requirement/pin policies
fail at frozen-policy validation before an attempt can be created.

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

Each selection pass obtains one immutable health batch for the complete
statically eligible pool. Provider Health scans intents once and replays unique
enclosing scopes once under its lock; the dispatcher never performs one locked
health read per candidate.

## Durable operational projection

`OperationalProjection` is a separate read-only catalog component layered over
routing policy, Attempts, and Provider Health. It joins bounded current
decision cells, durable live-attempt account counts, and authoritative scoped
health inspection. It does not call `Router`, select a route, or acquire an
admission/task-generation lock.

Account and model circuits for one route are sampled under one provider-health
lock hold, without repairing journals or publishing projections. Provider and
model filters apply to both account rows and decision rows, so the resulting
payload is one coherent scoped explanation rather than two differently scoped
views.

Each decision cell durably retains the project, task generation, strict subject,
optional admitted attempt ID, and complete sanitized `Decision#to_h`. This
preserves identity for a first no-route/capacity result even when no attempt
exists, and preserves the admitted attempt for a selected result after restart.
Enumeration is available only through a hard-bounded operator projection;
admission and reconciliation remain digest-addressed point reads and writes.

`hive circuits` renders this projection directly in human or closed
`hive-circuits.v1` JSON form. See [[commands/circuits]].

Sanitized adapter-channel inventory lives under
`test/fixtures/provider_errors/`. Each retained file records a sanitized real
capture or an explicit unavailable status, adapter version, observed channel,
and source-artifact digest without retaining raw messages. Claude's rejected
subscription `rate_limit_event` is the only currently enabled transport shape;
the admitted launch binding supplies its provider-account scope and the event
maps to `account_quota`. Real Codex and Grok failure events contain only
message text, while Pi has no configured subscription session on the evidence
host, so those adapters remain task-local rather than trusting synthetic
envelopes.

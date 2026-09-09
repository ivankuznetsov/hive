---
title: Hive::ProviderRouting
type: module
source: lib/hive/provider_routing.rb, lib/hive/provider_routing/*.rb
created: 2026-08-10
updated: 2026-09-04
tags: [config, provider-accounts, routing, stateless]
---

**TLDR**: `Hive::ProviderRouting` is a pure, stateless selector. Current global
provider accounts and the current stage configuration define the ordered route
pool. Current live attempts provide capacity. A provider-class retry carries
only the failed route ID, starts after that route, and wraps once. Hive stores
no provider policy, circuit, audit, probe, cooldown, or health state.

## Configuration

Provider accounts live in global Hive config because adapter sessions and
concurrency are shared across projects:

```yaml
providers:
  codex-primary:
    adapter: codex
    launch_binding: default
    models: [gpt-5.6-sol, gpt-5.6-terra]
    max_concurrent: 2
```

A stage opts in with an ordered pool plus optional hard requirements and pin:

```yaml
execute:
  routing:
    pool:
      - provider: codex-primary
        model: gpt-5.6-sol
        effort: xhigh
    required:
      quality: high
      tools: [filesystem]
    pin:
      provider: codex-primary
      model: gpt-5.6-sol
```

The account supplies the adapter and non-secret launch binding. Pool entries
cannot override them. Unknown accounts or models, duplicate routes, invalid
bindings, impossible requirements, and unmatched pins fail during config
loading. Projects without `routing.pool` use the legacy profile path and do not
read the global account registry.

## Selection

`Configuration`, `Policy`, `Request`, `Route`, `Candidate`, and `Decision` are
immutable values, not stored repositories. Selection is recomputed for every
admission:

1. Preserve configured route order.
2. Apply the hard pin and capability requirements.
3. Count `launching` and `running` attempts for each provider account.
4. For fresh work, begin at the first route. For a provider-class retry, begin
   after the failed route and wrap once. If that route no longer exists, begin
   at the first current route.
5. Select the first eligible route with live capacity.

A saturated pool is scheduler-owned and retryable. An exhausted hard pin or
otherwise incompatible pool returns `no_eligible_provider_route`. A failure
affects only the retry carrying that failed route; unrelated later work starts
from the first configured route again.

## Persistence boundary

The admitted attempt stores only the chosen route identity needed to launch and
explain that attempt. The recovery request may temporarily retain the current
policy digest and failed route so replay is deterministic, but there is no
SQLite routing-policy or provider-usability authority. `hive status` may show
the current decision attached to task recovery; there is no separate provider
administration command.

## Tests

- `test/unit/provider_routing/configuration_test.rb`
- `test/unit/provider_routing/router_test.rb`
- `test/unit/provider_routing/value_objects_test.rb`
- `test/integration/provider_routing_admission_test.rb`
- `test/integration/provider_routing_recovery_test.rb`

See [[modules/attempts]], [[modules/config]], and [[commands/status]].

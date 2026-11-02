---
title: Hive::ProviderRouting
type: module
source: lib/hive/provider_routing.rb, lib/hive/provider_routing/*.rb
created: 2026-08-10
updated: 2026-11-02
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

For the retained uncertainty and historical evidence, see [Refused-model classification (2026-10-16)](#refused-model-classification-2026-10-16).

- `test/unit/provider_routing/configuration_test.rb`
- `test/unit/provider_routing/router_test.rb`
- `test/unit/provider_routing/value_objects_test.rb`
- `test/integration/provider_routing_admission_test.rb`
- `test/integration/provider_routing_recovery_test.rb`

See [[modules/attempts]], [[modules/config]], and [[commands/status]].

## Known gaps

### Refused-model classification (2026-10-16)

#### Source S02, lines 27–36: Refused-model classification (2026-10-16)

ADR-057 treats Codex's `model is not supported when using Codex with a ChatGPT
account` as operator-owned configuration (`model_unsupported`). PR #1473 had
claimed ChatGPT plans also return this text when a model's plan allowance is
exhausted and the model works again later. Neither claim is verified against
Codex source or documentation. If the allowance case is real, those tasks now
wait for an operator retry instead of retrying hourly. Only this Codex sentence
is matched; other providers' "unknown model" errors still take their
generic error path (`provider_error`/`exit_code`) and the normal backoff.

### Provider-routing trusted captures (updated 2026-08-11)

#### Source S24, lines 552–564: Provider-routing trusted captures (updated 2026-08-11)

The U1 provider-routing policy includes a sanitized provenance inventory for
Claude, Codex, Pi, and Grok under `test/fixtures/provider_errors/`. A reviewed
Claude subscription capture now proves that rejected `five_hour` and
`seven_day` rate-limit events can be bound to the admitted account and safely
classified as provider-account `account_quota`. Real Codex and Grok failures
contain only message text, and no Pi subscription session is configured on the
evidence host, so those adapters and every exact-model class remain task-local.
Do not promote prose, HTTP-like text, synthetic fixtures, final messages,
prompt-derived output, or tool output into shared circuit evidence. Expand the
allowlist only after a reviewed, sanitized real subscription capture proves a
stable class and scope.

#### Source S59, lines 1395–1404: Provider transport coverage remains intentionally partial (2026-08-11)

The explicit provider-health implementation now enables only the real Claude
subscription rate-limit shape recorded in the provenance inventory. Synthetic
Claude, Codex, Pi, and Grok contract envelopes were removed from positive
tests because no current CLI emitted them. Before enabling another transport
class, retain a sanitized real subscription capture from that adapter's
structured transport or separately authenticated provider-diagnostic channel,
confirm stable account/model scope, and update the inventory. Until then,
unmatched provider output remains attempt-local and cannot open shared health.

### Provider-limit recovery is unit/integration-pinned but not post-fix live-smoked.

#### Source S28, lines 800–800: Open questions about the codebase

24. **Provider-limit recovery is unit/integration-pinned but not post-fix live-smoked.** `Hive::AgentLimit` and the headless and review writers classify quota/rate/usage-credit walls as `limits_reached` while filtering healthy UI-limit text. Provider reset dates remain visible estimates, but the daemon schedules readiness solely from the latest quota marker mtime, submits after the default one-hour interval even when the provider advertises a later date, and never exhausts a recovery budget. `test/unit/agent_limit_test.rb`, `test/unit/daemon/{stale_agent_healer,recovery_coordinator}_test.rb`, and `test/integration/daemon_auto_retry_test.rb` pin the display/scheduling split, shared cooldown, durable-history retry count, and repeated unbounded retries. No in-tree live artifact yet shows an installed daemon observing a real July-25-style hold, retrying after a user resets usage/switches account/tops up credits, and advancing the task while status/TUI retains the provider estimate. A large cohort limited at the same time can also become eligible in the same daemon tick; normal concurrency caps still bound dispatch, but that synchronized recovery shape has not been live load-smoked. 6-review reuses succeeded reviewer outputs only across a *triage*-limited retry ([[stages/review]] `ReviewerReuse`); a pass parked by a limited CI fixer at the clean boundary, or a `reviewer_partial_failure` whose only failed reviewer was quota-limited (a non-limit reason, so it is paced by the generic retry backoff, not the hourly limit cooldown), still re-runs every reviewer on retry. Reuse is not yet live-smoked against a real limited triage.

---
title: Harden provider routing review contracts
date: 2026-08-11T05:00:00Z
tags: [provider-health, provider-routing, attempts, recovery, review]
---

The stage-six review pass hardened explicit provider routing at its persistence
and recovery boundaries. Provider-health inspection is now non-mutating and
coherently snapshots enclosing scopes; mutation failures stay isolated to the
affected scope; journal limits and corrupt-tail recovery preserve replayable
state; configured cooldowns reach production stores; and operator mutations
retire stale probe ownership and intents.

Routing now validates effective launch-binding isolation and profile hard
limits, discovers the enclosing review route, consistently scopes operational
decisions, and uses shared digest, circuit-summary, exclusion, and taxonomy
contracts. Initial and terminal provider failures enter the single recovery
owner without requiring an attempt where none exists. The dispatch-request and
operational-status documentation now names the emitted v5 and v4 schemas.

The provider-limit E2E incident now keeps its real-process fallback proof and
adds durable AE2-AE8 coverage for multi-scope probes, restart and fencing,
strict pins, capacity, exhaustion, operator mutation, corruption repair, and
implicit versus explicit one-route pools. A second real CLI task verifies that
an unconfigured pool retains the legacy `limits_reached` marker and does not
write shared health or markerless routed recovery state.

---
title: Partition provider-routing E2E evidence by semantic coverage
tags: [e2e, provider-routing, provider-health, ci]
---

**Why:** The enabled provider-limit incident combined its time-sensitive daemon recovery proof with the independent AE2-AE8 durable matrix and legacy no-pool compatibility path. All behavior passed, but the combined scenario exceeded the advisory ten-second per-incident budget while the enabled incident aggregate stayed below thirty seconds.

**Change:** Kept `incident_provider_limit_retry` focused on the real provider failure, circuit opening, and one daemon-owned fallback successor. The fixture advances only the persisted one-second cooldown timestamp before starting the daemon, rather than spending wall time waiting for a known clock boundary. Moved the AE2-AE8 matrix and legacy no-pool subscription-limit isolation into `provider_routing_durable_matrix` with its own required `routing.provider_health_durability` semantic coverage. The legacy path now proves it creates neither provider-health files nor a routed recovery request.

**Boundary:** This is a test-evidence partition only. It does not change provider-health behavior, routing policy, agent compatibility metadata, retry budgets, or the CI timing thresholds.

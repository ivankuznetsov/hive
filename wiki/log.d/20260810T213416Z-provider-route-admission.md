---
date: 2026-08-10
title: Commit provider routes during durable admission
---

- Added pure deterministic candidate evaluation with stable pin, requirement,
  circuit, probe, and provider-capacity exclusions.
- Froze explicit policies before first selection and persisted the selected
  account, adapter, launch binding, model, effort, decision, circuit vector,
  and probe bindings with attempt schema v4.
- Derived provider concurrency from live durable attempts and kept all-route
  saturation scheduler-owned and mutation-free.
- Added complete route-generation CAS and crash-safe multi-scope probe claims
  under the admission, task-generation, and provider-health lock order.

---
date: 2026-07-25
summary: Freeze per-stage model routing in durable implementation identities
---

- Composed execute, open-PR, review-fix, and review-CI public model routes with
  the selected implementation identity while preserving its provider.
- Persisted concrete effective routing values and field provenance, then
  reconstructed typed profile-native arguments without rereading live config.
- Made each generation-and-stage selection first-writer-wins across retries and
  configuration drift, while retaining the flat-argument compatibility path
  for historical journals.
- Rejected invalid routed capability combinations before any identity event is
  appended.

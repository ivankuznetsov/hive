---
date: 2026-07-17
summary: Preserve durable attempt processes across daemon replacement
---

- Changed the shipped Linux daemon unit to `KillMode=process`, so systemd
  stop/restart targets the daemon while detached, lease-owned attempt wrappers
  and workers remain available for adoption by its replacement.
- Made orphan cleanup probe the recorded process group when its worker leader
  is missing. A live or unverifiable group now fails closed instead of being
  classified absent and permitting a concurrent successor.
- Added focused process-identity and rendered-service regressions for both
  lifecycle boundaries.

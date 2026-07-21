---
title: Harden native Hive web setup contracts
type: fix
date: 2026-07-20
tags: [web, setup, service, auth, schemas]
---

- Made managed bundle activation prepare writable dependencies and verified
  production assets before stamping, with bounded cosign verification.
- Kept foreground, managed-service, status, and error paths on one resolved
  environment and lifecycle contract; refreshed running services restart
  before local readiness is probed.
- Preserved loopback-proxy and authenticated LAN access without allowing local
  GitHub connection or inherited bypass state to change the authorization
  boundary.
- Tightened the published setup/web schemas and install-agent consent flow,
  and added regression coverage for service crash-loop guards and rejected
  Host mutations.

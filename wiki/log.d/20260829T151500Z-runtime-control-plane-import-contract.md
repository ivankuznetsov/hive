---
title: Freeze runtime control-plane import and payload contracts
date: 2026-08-29
tags: [sqlite, migration, recovery, payloads]
---

- Pinned the affected filesystem coordination inventory to 9,951 physical
  source lines at commit `1eab41d6b4bdac6664dc1e94ad1ccfb6ef604dd1`.
- Added migration-only legacy decoders with exact per-source dispositions and
  explicit quiescence gates for claimed requests, live attempts, capacity,
  provider probes, and task leases.
- Added stable open-payload custody, immutable content-addressed sealing, and
  an independently verifiable cutover/recovery-set manifest.
- Kept all three helpers out of normal runtime loading; no legacy consumer has
  switched authority yet.

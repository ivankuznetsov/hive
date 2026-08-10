---
date: 2026-07-24
summary: Put durable attempt admission behind one in-monorepo API
---

- Added `Hive::Attempts::API` as the stable admission boundary for foreground
  task commands, bot-local delivery, daemon queue delivery, and loss-successor
  recovery.
- Kept `Entrypoint`, `ConfiguredDispatcher`, launchers, clients, and stores in
  the Hive monorepo as internal collaborators, with Hive remaining the first
  and primary API consumer.
- Routed Hive's production admission consumers through the new boundary while
  preserving the existing durable-attempt behavior and result contracts.
- Separated the public result and unsupported-platform contracts from the
  internal client, dispatcher, and launcher implementations.
- Added focused coverage for API delegation, shared-store composition, and the
  CLI, bot, and daemon construction paths.

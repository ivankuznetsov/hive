---
title: Metrics adopts shared JSON envelope emission
date: 2026-08-13
tags: [metrics, json, cli, maintainability]
---

`Hive::Commands::Metrics` now uses `Hive::Schemas::EnvelopeEmitter` for its
error rescue, single-document guard, and output-failure handling. Its payload
hook preserves the published `hive-metrics-rollback-rate` v1 error allowlist,
including the intentional absence of `error_class`. This completes the
pre-existing command migration tracked by issue #35 without changing the CLI
wire contract.

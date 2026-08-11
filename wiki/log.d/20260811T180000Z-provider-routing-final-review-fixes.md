---
title: Provider routing final review hardening
date: 2026-08-11
tags: [provider-routing, provider-health, agent-cli-runtime, review]
---

- Raised the durable exclusion envelope to the actual four blockers possible
  for one provider/model candidate while retaining the 4,096 aggregate bound.
- Made impossible probe claims and ownerless outcomes fail replay closed, and
  made empty or first-record-truncated journals require explicit repair.
- Replaced per-event compaction writes with 64 bounded idempotency shards while
  keeping legacy point receipts readable.
- Moved subscription-session directory compatibility metadata into
  `agent-cli-runtime`, parity-tested Hive's temporary profile copy, rejected
  default/named session aliases, and defensively scrubbed Claude's ambient
  auth-token override for named subscription bindings.

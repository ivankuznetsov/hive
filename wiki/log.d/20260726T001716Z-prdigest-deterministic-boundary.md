---
title: Keep Hive catch-up policy out of PRDigest
type: log
tags: [digest, prdigest, scheduling, compatibility]
---

## [2026-07-26T00:17:16Z] digest — keep Hive catch-up policy out of PRDigest

**Action:** Stopped serializing Hive's `digest.max_catchup_days` into the
temporary PRDigest configuration. Hive always invokes deterministic
`prdigest run` for one explicit date, while Hive's daemon alone owns catch-up
scheduling. The adapter does not select PRDigest facts/prose modes or forward
AI-provider configuration or credentials.

**Coverage:** Added direct adapter coverage for Hive's supported unbounded
value `0` and an above-PRDigest-range value `31`, pinning the child YAML to
`timezone`, `github`, `telegram`, `digest`, and `state` only. Existing command
coverage continues to pin array argv, `prdigest-result` v1 passthrough, child
exit propagation, dry-run behavior, and private mode-`0600` config.

**Uncertainty:** No new uncertainty. This is a local serialization boundary;
the existing focused tests exercise both affected settings without network or
provider access.

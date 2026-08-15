---
title: Pin the OpenCode 1.18.16 integration contract
date: 2026-08-12
tags: [agent-cli-runtime, opencode, contract]
---

**Change:** Added sanitized OpenCode `1.18.16` fixtures for headless run/help,
local route and auth inventories, JSONL event streams, malformed evidence, and
sanitized session exports. The contract records that actual provider/model
identity comes from correlated export evidence rather than the requested route.

**Decision:** Superseded the April `1.14.25` support assessment with an opt-in
first-class profile design based on an invocation-owned overlay, caller-owned
process lifecycle, deny-first permissions, and native Compound Engineering
`3.21.4` skill/command registration. The historical exclusion remains in the
matrix as dated context.

**Verification:** `components/agent-cli-runtime/test/opencode_contract_test.rb`
validates every committed fixture, required terminal fields, nil-versus-zero
evidence boundaries, actual-route correlation, additive events, malformed
cases, and secret/home-path hygiene.

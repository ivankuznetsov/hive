---
title: Add isolated OpenCode prepared invocations
date: 2026-08-12
tags: [agent-cli-runtime, opencode, isolation, permissions]
---

**Change:** Registered OpenCode `1.18.16+` as the fifth component profile and
added immutable route, probe, permission-policy, preparation, and prepared
invocation values. Preparation stages a caller-selected non-secret provider
configuration beneath private XDG homes, validates the exact cached route and
variant without a model request, and compiles a discrete JSON run invocation.

**Safety:** OpenCode preparation ignores ambient project/global state, forwards
only caller-named credential variables, compiles deny-first `read-only` or
`workspace-write` rules, validates owner-controlled real paths, and exposes an
inode-checked idempotent cleanup operation. The component still does not spawn
or supervise the model process.

**Compatibility:** The existing four profiles keep their order, argv, generic
probe, preparation, and usage behavior. OpenCode is appended and requires its
typed preparation contract before the auto-approval flag can be emitted.

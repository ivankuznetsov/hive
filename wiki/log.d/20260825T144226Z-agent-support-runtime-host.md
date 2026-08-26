---
title: Narrow the provider runtime host
type: refactor
module: agent-support
tags: [agent-support, runtime, opencode, boundary]
---

Provider runtime facets now receive a small `RuntimePolicy::ProviderHost`
instead of the complete core runtime module. The host exposes only generic
policy constructors and bounded resolution helpers, keeping core process and
artifact authority out of provider packages.

OpenCode declares that it uses the generic portable managed runtime with a
constant on its support root. The generic host compiles that policy directly,
removing the empty OpenCode runtime adapter while retaining selective loading
and provider-neutral dispatch.

Generic plan-review callers treat provider hooks as optional and retain their
existing fallback behavior. Legacy custom profiles named `claude` also retain
their historical tool-scope flags through data owned by `AgentSupport`.

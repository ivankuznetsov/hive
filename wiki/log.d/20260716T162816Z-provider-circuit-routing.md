---
title: Provider-account circuit routing and resumable recovery
type: log
created: 2026-07-16
tags: [routing, providers, daemon, workflows, cli]
---

**Action:** Added validated provider accounts and ordered capability pools,
durable provider/model circuits with one real half-open probe, process-shared
attempt leases, adapter-owned failure normalization, and routed provider gates
across direct and daemon dispatch.

**Recovery:** Added the versioned resumable-workflow child snapshot contract,
workflow/generation dedup leases, generic daemon recovery, and the built-in
bench adapter that preserves complete/terminal artifacts.

**Operations:** Added task routing/circuit/probe events, the sanitized global
circuit audit, and `hive circuits` human/JSON inspection plus reasoned manual
provider/model clear.

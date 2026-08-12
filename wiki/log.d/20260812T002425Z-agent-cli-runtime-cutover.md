---
title: Hive consumes the published Agent CLI Runtime
type: change
date: 2026-08-12
---

Published and independently verified `agent-cli-runtime` 0.1.1, then replaced
Hive's temporary parity copy with the released component. Root development now
resolves `components/agent-cli-runtime`, installed Hive declares the compatible
RubyGems dependency, and packaged Web resolves 0.1.1 from the registry.

`Hive::AgentRuntime` remains a compatibility facade and `Hive::AgentProfile`
remains the custom extension point, but provider profiles, compilation,
bounded probes, capability checks, usage decoding, and result normalization now
come from `AgentCliRuntime`. Hive retains model-routing admission, skills,
default-model policy, status detection, and named subscription/session binding.
The four built-in Hive profiles reference the package profiles directly, and
the duplicated Pi/Grok preflight and usage-extractor implementations were
removed.

Hive now derives its launch-environment credential scrub from the component's
profile inventory for default and named routes, ordinary headless agents,
diagnosis spawns, display-name generation, native Codex review, and Claude tmux
sessions. Ambient API credentials therefore cannot replace the CLI
subscription/session selected by Hive; explicit session file selectors remain
available.

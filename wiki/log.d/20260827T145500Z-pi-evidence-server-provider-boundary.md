---
title: Keep Pi project-server evidence capability in the provider boundary
date: 2026-08-27
---

The AgentSupport extraction moved Pi evidence-tool construction out of
`RuntimePolicy`. Reconciliation with the project-evidence-server change keeps
`evidence_server` in `AgentSupport::Pi`: it is advertised and registered only
for non-Hive visual capture, while `CaptureToolkit` continues to own the
controller mailbox, project sandbox, and server lifecycle. The shared sandbox
parent helper also retains a no-exclusions default for controller callers.

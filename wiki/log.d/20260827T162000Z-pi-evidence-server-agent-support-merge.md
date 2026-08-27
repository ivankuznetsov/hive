---
title: Port Pi project evidence server through AgentSupport
date: 2026-08-27
tags: [artifacts, evidence, pi, agent-support]
---

The Pi evidence producer now exposes `evidence_server` through its AgentSupport
capture interface. The provider runtime registers that controller-owned tool
alongside browser capture, while `CaptureToolkit` keeps project-server lifetime
and sandbox enforcement on the controller side. `ProjectCommandSandbox` now
uses the current explicit parent-directory exclusion contract when assembling
its bubblewrap mount layout.

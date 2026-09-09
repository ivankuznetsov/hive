---
title: Keep Open PR provider launch policy in agent support
date: 2026-08-26
---

`Stages::OpenPr` now asks a selected provider-support facade for any
provider-specific authoring launch kwargs. OpenCode's exact draft-only edit
scope and validated-draft completion probe remain unchanged, but are owned by
`AgentSupport::OpenCode`, preserving the generic-stage boundary enforced by
the agent-support tests.

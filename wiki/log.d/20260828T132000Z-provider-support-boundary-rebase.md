---
title: Preserve provider-support boundaries after the durable checkpoint rebase
date: 2026-08-28
---

Rebased the durable-plan-checkpoint work onto current `main` and retained the
provider-neutral controller boundary: provider-specific credential scrubbing
and capture runtime capabilities are selected through `AgentSupport`, rather
than profile-name branches in the agent and artifact controllers.

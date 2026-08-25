---
title: Move OpenCode behavior behind AgentSupport
type: refactor
module: agent-support
tags: [agent-support, opencode, selective-loading, runtime]
---

OpenCode now owns its typed configuration, skill/setup inventory, managed
runtime policy, launch-scope translation, bounded run/export transaction,
route observation normalization, plan-review overlay, and protocol exceptions
under `Hive::AgentSupport::OpenCode`.

Hive core retains one provider-neutral bounded-process primitive plus durable
journal, artifact, credential-write, and workflow-transition authority. The
profile catalog no longer loads OpenCode; selecting it loads the small support
root and configuration, while execution, skills, and setup facets remain lazy.

The phase is guarded by clean-process loading tests and a current-source scan
that rejects OpenCode behavioral branches and legacy helper names outside the
support boundary. It also remains smaller than its exact preceding Pi
checkpoint in both raw and substantive production Ruby lines.

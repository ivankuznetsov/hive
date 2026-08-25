---
title: Claude support boundary
module: agent-support
date: 2026-08-25
---

- Moved Claude's stream protocol and accounting, credentials, native model,
  skill/plugin inventory, setup adapter, managed-runtime translation, TUI
  readiness grammar, wrapper argv, and skill-alias rules under
  `Hive::AgentSupport::Claude` with lazy facets.
- Replaced generic provider-name dispatch with the support facet convention.
  Core retains tmux/process custody, task markers, durable logs, artifact
  admission, credential writes, and workflow recovery.
- Reused Ruby module extension, autoload, callable, and convention lookup
  instead of adding registries or policy object graphs. The Claude phase is
  smaller than its exact Grok checkpoint in raw and substantive production
  Ruby lines.

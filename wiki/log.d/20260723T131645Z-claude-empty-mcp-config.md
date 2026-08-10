---
title: Claude-compatible empty MCP isolation config
date: 2026-07-23
tags: [agents, claude, runtime-policy, digest]
---

Managed Claude launches now materialize their intentionally empty strict MCP
configuration as an explicit `mcpServers: {}` object. This preserves complete
MCP isolation while satisfying current Claude Code schema validation, allowing
confidential digest generation and managed Honeycomb actors to start normally.

Unit coverage pins the schema-valid empty configuration.

**Links:** [[modules/agent_profile]], [[commands/digest]], [[testing]]

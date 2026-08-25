---
title: Grok support boundary
module: agent-support
date: 2026-08-25
---

- Moved Grok's message protocol, subscription credential precedence, auth
  environment, default-model discovery, skill/plugin inventory, setup adapter,
  runtime provenance checks, and managed bubblewrap policy under
  `Hive::AgentSupport::Grok` with lazy runtime, skills, and setup facets.
- Kept process supervision, portable-policy validation, output materialization,
  credential reads, and workflow transitions in generic core.
- Reused the shared Ruby skill-policy mixin, provider convention loader, and
  portable runtime host methods. The Grok phase is smaller than its exact Codex
  checkpoint in both raw and substantive production Ruby lines.

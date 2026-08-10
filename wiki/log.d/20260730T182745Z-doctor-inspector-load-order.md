---
title: Make Doctor inspector loading deterministic
type: change
created: 2026-07-30
tags: [doctor, cli, json, load-order]
---

- Made `Hive::Commands::Doctor` own its ordered summary keys and construct the
  inspector through the supported `Hive::AgentSkills.hive_inspector` facade,
  instead of depending on an earlier command or test to define an internal
  constant.
- Direct Ruby callers can now inject an inspector and render the
  `hive-doctor.v2` summary in a fresh process without a load-order failure.
- Made the standalone init Doctor, init-agent-skills, setup-orchestrator, and
  uninstall test files declare the internal constants they instantiate, so
  their documented single-file commands are deterministic.
- Kept production consumers behind the public skillpack facade; the component
  boundary contract prevents Doctor from requiring inspector internals.

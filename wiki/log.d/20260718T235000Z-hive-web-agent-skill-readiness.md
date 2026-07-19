---
title: Bring managed agent-skill readiness to Hive Web
created: 2026-07-18T23:50:00Z
tags: [web, agents, skills, doctor, provisioning]
---

- Added explicit per-project managed-skill health checks to the Agents page,
  using the same Inspector payload that backs `hive doctor`.
- Added a confirmation-gated safe repair action through the shared
  `SetupAgents` command with a non-TTY input and `web_confirmed` consent
  provenance; conflicting and user-owned custom skills remain untouched.
- Kept expensive native CLI inventory opt-in instead of running it for every
  registered project whenever the Agents page opens.
- Added unit coverage for the web adapter boundary and request coverage for
  health rendering, consent enforcement, repair, and the no-automatic-scan
  performance contract.

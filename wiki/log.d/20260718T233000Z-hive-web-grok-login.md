---
title: Expose Grok device login in Hive Web
created: 2026-07-18T23:30:00Z
tags: [web, agents, grok, authentication]
---

- Connected the existing Grok device-auth relay to the Agents page and its
  constrained start, status, and completion routes.
- Corrected the Agents page's persistence copy for both local and container
  installs instead of describing every installation as a `/data` mount.
- Added request-level coverage that distinguishes Grok's operator-ward device
  flow from Pi's token form.

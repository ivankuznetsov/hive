---
title: Make local Hive Web sessions fully operable
created: 2026-07-18T23:00:00Z
tags: [web, auth, repositories, local-mode]
---

- Exposed Status, Repos, Agents, and Telegram navigation to operators using the
  loopback connection-auth bypass, with a clear Local identity and an explicit
  GitHub connection action for account-dependent repository browsing.
- Made browser-driven repository setup explicitly non-interactive so agent-skill
  preflight additions cannot inherit Puma's terminal and leave an HTTP request
  waiting for an answer that the browser cannot provide.
- Added integration coverage for local navigation, repository reconnect copy,
  and the non-TTY init boundary.

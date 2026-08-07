---
title: Setup now supervises the PR babysitter
date: 2026-08-07
tags: [setup, babysitter, systemd, launchd]
---

`hive setup` now installs and starts a separate per-user PR babysitter service
on systemd-user and launchd hosts. `hive babysit install --force` is the direct
repair surface, and uninstall removes the managed unit. The foreground service
still acts only on projects with `babysitter.enabled: true`, preserves custom
Hive/XDG state roots without persisting provider secrets, and uses bounded
stop/respawn behavior for active repair agents. Setup safely drains an existing
detached babysitter before manager takeover, while uninstall reuses the same
ownership-aware drain before any service or data removal.
Projects can select a dedicated `babysitter.agent` and route it through
`models.babysitter`; omitting the agent preserves the `execute.agent` fallback.
